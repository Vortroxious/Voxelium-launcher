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

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <pthread.h>

#define _GLFW_BUILD_DLL  // GLFWAPI = default visibility
#define GLFW_INCLUDE_NONE
#include "glfw/GLFW/glfw3.h"

#define EGL_EGL_PROTOTYPES 0
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>

#import "ZLGLFW.h"

// Keep every API function in the executable's export trie even though nothing
// in the app calls them directly.
#define ZLAPI __attribute__((used, visibility("default")))

#pragma mark - Errors

static GLFWerrorfun gErrorCallback;
static int gLastError;
static char gLastErrorDescription[512];

static void zlError(int code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(gLastErrorDescription, sizeof(gLastErrorDescription), fmt, ap);
    va_end(ap);
    gLastError = code;
    NSLog(@"[ZLGLFW] error 0x%X: %s", code, gLastErrorDescription);
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

static BOOL zlLoadEGL(void) {
    if (gDisplay != EGL_NO_DISPLAY) return YES;
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libEGL.framework/libEGL"];
    gEGLLib = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!gEGLLib) {
        zlError(GLFW_PLATFORM_UNAVAILABLE, "cannot load ANGLE libEGL: %s", dlerror());
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
        zlError(GLFW_PLATFORM_UNAVAILABLE, "ANGLE libEGL is missing entry points");
        return NO;
    }
    EGLint attrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
    EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, attrs);
    if (dpy == EGL_NO_DISPLAY || !p_eglInitialize(dpy, NULL, NULL)) {
        zlError(GLFW_PLATFORM_UNAVAILABLE, "eglInitialize failed: 0x%X", p_eglGetError());
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
        zlError(GLFW_PLATFORM_UNAVAILABLE, "no suitable EGL config: 0x%X", p_eglGetError());
        p_eglTerminate(dpy);
        return NO;
    }
    gDisplay = dpy;
    return YES;
}

#pragma mark - Main-thread helper

static void zlOnMain(dispatch_block_t block) {
    if (NSThread.isMainThread) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

#pragma mark - Events

typedef enum {
    ZLEventCursorPos, ZLEventMouseButton, ZLEventScroll, ZLEventKey, ZLEventChar,
    ZLEventFramebufferSize, ZLEventWindowSize, ZLEventClose, ZLEventFocus,
} ZLEventType;

typedef struct {
    ZLEventType type;
    void *window;   // GLFWwindow *
    double x, y;    // cursor / scroll
    int a, b, c, d; // button/key, action, mods, scancode or codepoint
} ZLEvent;

static pthread_mutex_t gEventLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gEventCond = PTHREAD_COND_INITIALIZER;
static ZLEvent *gEvents;
static size_t gEventCount, gEventCapacity;
static BOOL gEmptyEventPosted;

static void zlPush(ZLEvent e) {
    pthread_mutex_lock(&gEventLock);
    if (gEventCount == gEventCapacity) {
        gEventCapacity = gEventCapacity ? gEventCapacity * 2 : 256;
        gEvents = realloc(gEvents, gEventCapacity * sizeof(ZLEvent));
    }
    gEvents[gEventCount++] = e;
    pthread_cond_signal(&gEventCond);
    pthread_mutex_unlock(&gEventLock);
}

#pragma mark - Window object

@class ZLGLFWView;

@interface ZLGLFWWindowObj : NSObject {
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
@property (nonatomic, strong) ZLGLFWView *view;
@property (nonatomic, copy) NSString *title;
@end

@implementation ZLGLFWWindowObj
@end

static NSMutableArray<ZLGLFWWindowObj *> *gWindows;
static ZLGLFWWindowObj *gVisibleWindow;
static __thread ZLGLFWWindowObj *__unsafe_unretained tCurrent;

static inline ZLGLFWWindowObj *W(GLFWwindow *w) { return (__bridge ZLGLFWWindowObj *)(void *)w; }
static inline GLFWwindow *H(ZLGLFWWindowObj *w) { return (GLFWwindow *)(__bridge void *)w; }

#pragma mark - Keyboard mapping (USB HID usage -> GLFW key)

static int zlKeyFromHID(long usage) {
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

static int zlMods(UIKeyModifierFlags f) {
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

static void zlSendKey(ZLGLFWWindowObj *w, int key, int action) {
    if (!w) return;
    zlPush((ZLEvent){.type = ZLEventKey, .window = H(w), .a = key, .b = action, .c = 0, .d = glfwGetKeyScancode(key)});
}

static void zlSendButton(ZLGLFWWindowObj *w, int button, int action) {
    if (!w) return;
    zlPush((ZLEvent){.type = ZLEventMouseButton, .window = H(w), .a = button, .b = action});
}

static void zlSendScroll(ZLGLFWWindowObj *w, double dy) {
    if (!w) return;
    zlPush((ZLEvent){.type = ZLEventScroll, .window = H(w), .x = 0, .y = dy});
}

static void zlSendChar(ZLGLFWWindowObj *w, UTF32Char cp) {
    if (!w || cp < 32 || cp == 127) return;
    zlPush((ZLEvent){.type = ZLEventChar, .window = H(w), .a = (int)cp});
}

#pragma mark - Haptics (as Amethyst: light on button press / tap, medium on long press)

static UIImpactFeedbackGenerator *zlLightHaptic(void) {
    static UIImpactFeedbackGenerator *g;
    if (!g) { g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [g prepare]; }
    return g;
}

static UIImpactFeedbackGenerator *zlMediumHaptic(void) {
    static UIImpactFeedbackGenerator *g;
    if (!g) { g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [g prepare]; }
    return g;
}

#pragma mark - On-screen controls (Amethyst/PojavLauncher default layout)

// Layout and behaviour follow Amethyst-iOS's built-in default control layout
// (Natives/customcontrols/CustomControlsUtils.m, generateAndSaveDefaultControl,
// GPL-3.0). Its positions are expressions over the screen size in pixels; they
// are evaluated here in points with button_scale = 100 and margin = 2 pt.

typedef NS_ENUM(NSInteger, ZLSpecial) {
    ZLSpecialNone, ZLSpecialRuntimeMenu, ZLSpecialHideGUI, ZLSpecialKeyboard, ZLSpecialVirtualMouse, ZLSpecialDrawer,
};

@class ZLControlsOverlay;

@interface ZLControlButton : UIButton
@property (nonatomic, weak) ZLGLFWWindowObj *owner;
@property (nonatomic, weak) ZLControlsOverlay *overlayRef;
@property (nonatomic) int key;          // GLFW key, or GLFW_KEY_UNKNOWN
@property (nonatomic) int mouseButton;  // GLFW mouse button, or -1
@property (nonatomic) ZLSpecial special;
@property (nonatomic) BOOL toggle, latched, inGame, inMenu, inDrawer;
@property (nonatomic) CGSize size;      // points
@property (nonatomic, copy) CGPoint (^origin)(CGFloat W, CGFloat H);
@end

@interface ZLControlsOverlay : UIView
@property (nonatomic, weak) ZLGLFWWindowObj *owner;
@property (nonatomic, weak) UIView *gameView;
@property (nonatomic) BOOL inGame, guiHidden, drawerOpen, virtualMouse;
@property (nonatomic, strong) UIImageView *pointer;
- (instancetype)initWithOwner:(ZLGLFWWindowObj *)owner;
- (void)special:(ZLSpecial)special from:(ZLControlButton *)button;
- (void)toggleKeyboard;
- (void)refresh;
@end

@implementation ZLControlButton

+ (instancetype)named:(NSString *)title size:(CGSize)size {
    ZLControlButton *b = [self buttonWithType:UIButtonTypeCustom];
    b.key = GLFW_KEY_UNKNOWN;
    b.mouseButton = -1;
    b.size = size;
    b.inGame = b.inMenu = YES;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.numberOfLines = 2;
    b.titleLabel.textAlignment = NSTextAlignmentCenter;
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0x4d / 255.0];  // Amethyst bgColor 0x4d000000
    b.layer.borderColor = UIColor.whiteColor.CGColor;
    [b addTarget:b action:@selector(down) forControlEvents:UIControlEventTouchDown];
    [b addTarget:b action:@selector(up) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return b;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) / 2;  // cornerRadius 100%
}

- (void)setPressedLook:(BOOL)pressed {
    self.backgroundColor = pressed ? [UIColor colorWithWhite:1 alpha:0.35] : [UIColor colorWithWhite:0 alpha:0x4d / 255.0];
}

- (void)send:(int)action {
    if (self.key != GLFW_KEY_UNKNOWN) zlSendKey(self.owner, self.key, action);
    if (self.mouseButton >= 0) zlSendButton(self.owner, self.mouseButton, action);
}

- (void)down {
    [zlLightHaptic() impactOccurred];
    if (self.special != ZLSpecialNone) {
        [self.overlayRef special:self.special from:self];
        return;
    }
    if (self.toggle) {
        self.latched = !self.latched;
        [self send:self.latched ? GLFW_PRESS : GLFW_RELEASE];
        [self setPressedLook:self.latched];
    } else {
        [self send:GLFW_PRESS];
        [self setPressedLook:YES];
    }
}

- (void)up {
    if (self.special != ZLSpecialNone || self.toggle) return;
    [self send:GLFW_RELEASE];
    [self setPressedLook:NO];
}

- (void)releaseLatched {
    if (self.latched) {
        self.latched = NO;
        [self send:GLFW_RELEASE];
        [self setPressedLook:NO];
    }
}

@end

// Movement stick (Amethyst default: 204.8 pt, bottom-left, relative, no forward lock).
@interface ZLJoystick : UIView
@property (nonatomic, weak) ZLGLFWWindowObj *owner;
@end

@implementation ZLJoystick {
    UIView *_knob;
    int _held;  // bit 0 W, 1 S, 2 A, 3 D
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0x4d / 255.0];
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:0 alpha:0x4d / 255.0].CGColor;  // strokeColor 1291845632
        _knob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 72, 72)];
        _knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
        _knob.layer.cornerRadius = 36;
        _knob.userInteractionEnabled = NO;
        [self addSubview:_knob];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.width / 2;
    if (!_held) _knob.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
}

- (void)apply:(int)held {
    static const int keys[4] = {GLFW_KEY_W, GLFW_KEY_S, GLFW_KEY_A, GLFW_KEY_D};
    for (int i = 0; i < 4; i++) {
        BOOL was = (_held >> i) & 1, now = (held >> i) & 1;
        if (was != now) zlSendKey(self.owner, keys[i], now ? GLFW_PRESS : GLFW_RELEASE);
    }
    _held = held;
}

- (void)track:(UITouch *)t {
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGPoint p = [t locationInView:self];
    CGFloat r = self.bounds.size.width / 2;
    CGFloat dx = (p.x - c.x) / r, dy = (p.y - c.y) / r;
    CGFloat len = hypot(dx, dy);
    if (len > 1) { dx /= len; dy /= len; }
    _knob.center = CGPointMake(c.x + dx * r * 0.6, c.y + dy * r * 0.6);
    int held = 0;
    if (dy < -0.35) held |= 1;
    if (dy > 0.35) held |= 2;
    if (dx < -0.35) held |= 4;
    if (dx > 0.35) held |= 8;
    [self apply:held];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [zlLightHaptic() impactOccurred];
    [self track:touches.anyObject];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self track:touches.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self reset]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self reset]; }

- (void)reset {
    [self apply:0];
    _knob.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
}

@end

// Hidden first responder that brings up the iOS keyboard (world names, chat,
// signs) and turns typing into GLFW char/key events.
@interface ZLKeyboardProxy : UIView <UIKeyInput>
@property (nonatomic, weak) ZLGLFWWindowObj *owner;
@property (nonatomic) UITextAutocorrectionType autocorrectionType;
@property (nonatomic) UITextAutocapitalizationType autocapitalizationType;
@property (nonatomic) UITextSpellCheckingType spellCheckingType;
@property (nonatomic) UIReturnKeyType returnKeyType;
@end

@implementation ZLKeyboardProxy
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.autocorrectionType = UITextAutocorrectionTypeNo;
        self.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.spellCheckingType = UITextSpellCheckingTypeNo;
        self.returnKeyType = UIReturnKeyDone;
        self.userInteractionEnabled = NO;
    }
    return self;
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (void)insertText:(NSString *)text {
    ZLGLFWWindowObj *w = self.owner;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *s, NSRange r, NSRange er, BOOL *stop) {
        if ([s isEqualToString:@"\n"]) {
            zlSendKey(w, GLFW_KEY_ENTER, GLFW_PRESS);
            zlSendKey(w, GLFW_KEY_ENTER, GLFW_RELEASE);
            return;
        }
        UTF32Char cp = 0;
        if ([s getBytes:&cp maxLength:sizeof(cp) usedLength:NULL encoding:NSUTF32LittleEndianStringEncoding
                options:0 range:NSMakeRange(0, s.length) remainingRange:NULL]) zlSendChar(w, cp);
    }];
}
- (void)deleteBackward {
    zlSendKey(self.owner, GLFW_KEY_BACKSPACE, GLFW_PRESS);
    zlSendKey(self.owner, GLFW_KEY_BACKSPACE, GLFW_RELEASE);
}
@end

@implementation ZLControlsOverlay {
    NSMutableArray<ZLControlButton *> *_buttons;
    ZLJoystick *_stick;
    ZLKeyboardProxy *_keyboard;
    CGSize _loggedSize;
}

- (instancetype)initWithOwner:(ZLGLFWWindowObj *)owner {
    if ((self = [super initWithFrame:CGRectZero])) {
        _owner = owner;
        _buttons = [NSMutableArray array];
        const CGFloat m = 2, a = 69.6, b = 104.8, d = 96, dh = 40;

        // Right-hand cluster (x/y from Amethyst's expressions, simplified).
        [self add:@"Jump" key:GLFW_KEY_SPACE w:a h:a game:YES menu:NO
               at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.94878495 * W - a, 0.31131014 * H + a + m); }];
        [self add:@"Shift" key:GLFW_KEY_LEFT_SHIFT w:a h:a game:YES menu:YES
               at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.94878495 * W - a, 0.31131014 * H); }].toggle = YES;
        [self add:@"Sprint" key:GLFW_KEY_LEFT_CONTROL w:a h:a game:YES menu:NO
               at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.94878495 * W - 2 * a - m, 0.31131014 * H); }].toggle = YES;
        [self add:@"Right\nClick" mouse:GLFW_MOUSE_BUTTON_RIGHT w:a h:a
               at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.8756154 * W - a, 0.8178498 * H - a); }];
        [self add:@"Left\nClick" mouse:GLFW_MOUSE_BUTTON_LEFT w:a h:a
               at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.7756397 * W - a, 0.8224885 * H - a); }];
        [self add:@"Middle\nClick" mouse:GLFW_MOUSE_BUTTON_MIDDLE w:a h:a
               at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0.83548373 * W - a, 0.67798775 * H - a); }];
        // Inventory (E): Amethyst has it in the top row; moved, at the user's request, into the
        // right-hand cluster, just right of Right Click and below Jump (in reach of the right thumb).
        [self add:@"Inven-\ntory" key:GLFW_KEY_E w:a h:a game:YES menu:NO
               at:^CGPoint(CGFloat W, CGFloat H) {
                   return CGPointMake(0.8756154 * W + m, MAX(0.8178498 * H - a, 0.31131014 * H + 2 * a + 2 * m));
               }];

        // Top row, packed from the right edge.
        ZLControlButton *menuBtn = [self add:@"Runtime\nMenu" key:GLFW_KEY_UNKNOWN w:b h:39.2 game:YES menu:YES
               at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(W - a - b - m, 0); }];
        menuBtn.special = ZLSpecialRuntimeMenu;
        ZLControlButton *hide = [self add:@"Hide\nGUI" key:GLFW_KEY_UNKNOWN w:a h:40 game:YES menu:YES
               at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(W - a, 0); }];
        hide.special = ZLSpecialHideGUI;
        [self add:@"Pause" key:GLFW_KEY_ESCAPE w:b h:39.2 game:YES menu:NO
               at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(W - a - 2 * b - 2 * m, 0); }];
        [self add:@"Exit\nMenu" key:GLFW_KEY_ESCAPE w:b h:39.2 game:NO menu:YES
               at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(W - a - 2 * b - 2 * m, 0); }];

        // "More" drawer (top-left) and its items.
        ZLControlButton *more = [self add:@"More" key:GLFW_KEY_UNKNOWN w:d h:dh game:YES menu:YES
               at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0, 0); }];
        more.special = ZLSpecialDrawer;
        more.layer.borderWidth = 1.5;
        const CGFloat dy = 0.0026855469;
        [self drawer:@"Third\nperson" key:GLFW_KEY_F5 at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(d + m, dy * H); }];
        [self drawer:@"Debug\nMenu" key:GLFW_KEY_F3 at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(3 * (d + m), dy * H); }];
        [self drawer:@"Mouse\nToggle" key:GLFW_KEY_UNKNOWN at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(2 * (d + m), dy * H + dh + m); }].special = ZLSpecialVirtualMouse;
        [self drawer:@"Chat" key:GLFW_KEY_T at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(0, dy * H + dh + m); }];
        [self drawer:@"Keyboard" key:GLFW_KEY_UNKNOWN at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(d + m, dy * H + dh + m); }].special = ZLSpecialKeyboard;
        // Amethyst's expression puts Player List above the screen (y < 0); it is placed in the free slot at the top instead.
        [self drawer:@"Player\nList" key:GLFW_KEY_TAB at:^CGPoint(CGFloat W, CGFloat H) { return CGPointMake(2 * (d + m), dy * H); }].toggle = YES;

        _stick = [[ZLJoystick alloc] initWithFrame:CGRectZero];
        _stick.owner = owner;
        [self addSubview:_stick];

        _keyboard = [[ZLKeyboardProxy alloc] initWithFrame:CGRectZero];
        _keyboard.owner = owner;
        [self addSubview:_keyboard];

        _pointer = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"cursorarrow"]];
        _pointer.tintColor = UIColor.whiteColor;
        _pointer.layer.shadowOpacity = 0.8;
        _pointer.layer.shadowRadius = 1.5;
        _pointer.layer.shadowOffset = CGSizeZero;
        _pointer.userInteractionEnabled = NO;
        _pointer.hidden = YES;
        [self addSubview:_pointer];
        [self refresh];
    }
    return self;
}

- (ZLControlButton *)add:(NSString *)name key:(int)key w:(CGFloat)w h:(CGFloat)h game:(BOOL)game menu:(BOOL)menu
                      at:(CGPoint (^)(CGFloat, CGFloat))origin {
    ZLControlButton *btn = [ZLControlButton named:name size:CGSizeMake(w, h)];
    btn.owner = self.owner;
    btn.overlayRef = self;
    btn.key = key;
    btn.inGame = game;
    btn.inMenu = menu;
    btn.origin = origin;
    [_buttons addObject:btn];
    [self addSubview:btn];
    return btn;
}

- (ZLControlButton *)add:(NSString *)name mouse:(int)mouse w:(CGFloat)w h:(CGFloat)h at:(CGPoint (^)(CGFloat, CGFloat))origin {
    ZLControlButton *btn = [self add:name key:GLFW_KEY_UNKNOWN w:w h:h game:YES menu:YES at:origin];
    btn.mouseButton = mouse;
    return btn;
}

- (ZLControlButton *)drawer:(NSString *)name key:(int)key at:(CGPoint (^)(CGFloat, CGFloat))origin {
    ZLControlButton *btn = [self add:name key:key w:96 h:40 game:YES menu:YES at:origin];
    btn.inDrawer = YES;
    return btn;
}

- (void)refresh {
    for (ZLControlButton *btn in _buttons) {
        BOOL shown = self.inGame ? btn.inGame : btn.inMenu;
        if (btn.inDrawer) shown = shown && self.drawerOpen;
        if (self.guiHidden && btn.special != ZLSpecialHideGUI) shown = NO;
        btn.hidden = !shown;
    }
    _stick.hidden = !self.inGame || self.guiHidden;  // joystick: in game only
    self.pointer.hidden = !(self.virtualMouse && !self.inGame);
}

- (void)setInGame:(BOOL)inGame {
    if (_inGame == inGame) return;
    _inGame = inGame;
    if (!inGame) {
        // Leaving the game (menu, inventory, chat): release movement and latched keys.
        [_stick reset];
        for (ZLControlButton *btn in _buttons) if (btn.key == GLFW_KEY_LEFT_CONTROL) [btn releaseLatched];
    }
    [self refresh];
    [self logControls];
}

- (void)toggleKeyboard {
    if (_keyboard.isFirstResponder) {
        [_keyboard resignFirstResponder];
        [self.gameView becomeFirstResponder];  // keep hardware keyboard input
    } else {
        [_keyboard becomeFirstResponder];
    }
}

- (void)special:(ZLSpecial)special from:(ZLControlButton *)button {
    switch (special) {
        case ZLSpecialHideGUI:
            self.guiHidden = !self.guiHidden;
            [self refresh];
            break;
        case ZLSpecialDrawer:
            self.drawerOpen = !self.drawerOpen;
            [self refresh];
            break;
        case ZLSpecialKeyboard:
            [self toggleKeyboard];
            break;
        case ZLSpecialVirtualMouse:
            self.virtualMouse = !self.virtualMouse;
            [self refresh];
            break;
        case ZLSpecialRuntimeMenu: {
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Zalith iOS" message:nil
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Show / hide keyboard" style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *x) { [self toggleKeyboard]; }]];
            [sheet addAction:[UIAlertAction actionWithTitle:self.virtualMouse ? @"Virtual mouse: on" : @"Virtual mouse: off"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *x) { [self special:ZLSpecialVirtualMouse from:nil]; }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Quit game (saves the world)" style:UIAlertActionStyleDestructive
                                                    handler:^(UIAlertAction *x) {
                if (self.owner) zlPush((ZLEvent){.type = ZLEventClose, .window = H(self.owner)});
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            sheet.popoverPresentationController.sourceView = button;
            UIViewController *vc = self.window.rootViewController;
            [vc presentViewController:sheet animated:YES completion:nil];
            break;
        }
        case ZLSpecialNone:
            break;
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == _keyboard || hit == _pointer) ? nil : hit;
}

// Diagnostics: where each control is and what is visible (stderr goes to jvm.log).
- (void)logControls {
    NSMutableString *row = [NSMutableString string];
    for (ZLControlButton *btn in _buttons)
        if (!btn.inDrawer)
            [row appendFormat:@" [%@ %.0f,%.0f%@]", [btn.currentTitle stringByReplacingOccurrencesOfString:@"\n" withString:@" "],
                btn.frame.origin.x, btn.frame.origin.y, btn.hidden ? @" hidden" : @""];
    NSLog(@"[ZLGLFW] controls %.0fx%.0f pt, inGame=%d:%@", self.bounds.size.width, self.bounds.size.height, self.inGame, row);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    for (ZLControlButton *btn in _buttons) {
        CGPoint o = btn.origin(W, H);
        // Keep every control on screen (Amethyst clamps the same way when loading).
        o.x = MIN(MAX(o.x, 0), W - btn.size.width);
        o.y = MIN(MAX(o.y, 0), H - btn.size.height);
        btn.frame = (CGRect){o, btn.size};
    }
    if (!CGSizeEqualToSize(_loggedSize, self.bounds.size)) {
        _loggedSize = self.bounds.size;
        [self logControls];
    }
    const CGFloat stick = 204.8;
    _stick.frame = CGRectMake(0.02326631 * W, 0.9753418 * H - stick, stick, stick);
}

@end

#pragma mark - Game view (touch + hardware keyboard)

@interface ZLGLFWView : UIView
@property (nonatomic, weak) ZLGLFWWindowObj *owner;
@property (nonatomic, strong) ZLControlsOverlay *overlay;
@end

// Touch diagnostics, logged when the window is destroyed (stderr ends up in jvm.log).
static int gTouchBegan, gTouchMoved, gTouchMovedAccepted, gTouchEnded, gTouchCancelled, gHotbarSelects;

// Gestures on the game view outside the controls (as Amethyst):
//   in game:  drag = look, tap = use/place (right click), long press = break (hold left),
//             tap on the hotbar = select that slot (keys 1-9);
//   in menus: direct touch pointer, or a trackpad-style pointer with Mouse Toggle.
static const CFTimeInterval kLongPress = 0.35;
static const CGFloat kTapSlop = 12;

@implementation ZLGLFWView {
    UITouch *_primary, *_secondary;
    UITouch *_hotbarTouch;    // in game: a finger on the hotbar (independent of the look finger)
    int _hotbarSlot;
    CGPoint _lastPrimary, _startPrimary;
    CFTimeInterval _startTime;
    BOOL _primaryInGame, _primaryVirtual, _moved, _holding;
    NSUInteger _gestureGeneration;
    CGPoint _virtualCursor;
}

+ (Class)layerClass { return CAMetalLayer.class; }

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)pushCursor:(CGPoint)p {
    ZLGLFWWindowObj *w = self.owner;
    if (!w) return;
    zlPush((ZLEvent){.type = ZLEventCursorPos, .window = H(w), .x = p.x, .y = p.y});
}

// Minecraft hotbar slot under a point (auto GUI scale), or -1.
- (int)hotbarSlotAt:(CGPoint)p {
    ZLGLFWWindowObj *w = self.owner;
    if (!w || w->fbWidth <= 0) return -1;
    int fbW = w->fbWidth, fbH = w->fbHeight, s = 1;
    while (s < fbW && s < fbH && fbW / (s + 1) >= 320 && fbH / (s + 1) >= 240) s++;
    CGFloat x = p.x * w->scale, y = p.y * w->scale;
    CGFloat left = (fbW / s / 2.0 - 91) * s, top = (fbH / s - 22.0) * s;
    if (y < top || x < left || x >= left + 182.0 * s) return -1;
    int slot = (int)((x - left) / (20.0 * s));
    return slot >= 0 && slot <= 8 ? slot : -1;
}

- (void)selectHotbarSlot:(int)slot {
    ZLGLFWWindowObj *w = self.owner;
    if (!w || slot < 0 || slot > 8) return;
    _hotbarSlot = slot;
    gHotbarSelects++;
    [zlLightHaptic() impactOccurred];
    zlSendKey(w, GLFW_KEY_1 + slot, GLFW_PRESS);
    zlSendKey(w, GLFW_KEY_1 + slot, GLFW_RELEASE);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    gTouchBegan += (int)touches.count;
    ZLGLFWWindowObj *w = self.owner;
    if (!w) return;
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        // In game, a touch that lands on the hotbar selects that slot right away and
        // owns the hotbar until it lifts: sliding along it changes slot, as in Amethyst.
        // It never looks, uses, breaks or drops (no hold-to-drop, at the user's request).
        int slot = -1;
        BOOL inGame = w->cursorMode == GLFW_CURSOR_DISABLED;
        if (inGame && p.y > self.bounds.size.height * 0.85) {
            // Diagnostics for hotbar hits (bottom of the screen only).
            NSLog(@"[ZLGLFW] bottom touch at %.0f,%.0f pt (fb %dx%d, scale %.2f) -> hotbar slot %d",
                  p.x, p.y, w->fbWidth, w->fbHeight, w->scale, [self hotbarSlotAt:p]);
        }
        if (!_hotbarTouch && inGame && (slot = [self hotbarSlotAt:p]) >= 0) {
            _hotbarTouch = t;
            _hotbarSlot = -1;
            [self selectHotbarSlot:slot];
            continue;
        }
        if (!_primary) {
            _primary = t;
            _lastPrimary = _startPrimary = p;
            _startTime = CACurrentMediaTime();
            _primaryInGame = w->cursorMode == GLFW_CURSOR_DISABLED;
            _primaryVirtual = !_primaryInGame && self.overlay.virtualMouse;
            _moved = NO;
            _holding = NO;
            if (_primaryInGame || _primaryVirtual) {
                // Tap vs long press is decided later; a still, held finger presses the left button.
                NSUInteger gen = ++_gestureGeneration;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLongPress * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (gen != self->_gestureGeneration || !self->_primary || self->_moved || self->_holding) return;
                    self->_holding = YES;
                    [zlMediumHaptic() impactOccurred];
                    zlSendButton(self.owner, GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS);
                });
            } else {
                [self pushCursor:p];
                zlSendButton(w, GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS);
            }
        } else if (!_secondary && !_primaryInGame && !_primaryVirtual) {
            _secondary = t;
            zlSendButton(w, GLFW_MOUSE_BUTTON_RIGHT, GLFW_PRESS);
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    gTouchMoved++;
    ZLGLFWWindowObj *w = self.owner;
    if (w && _hotbarTouch && [touches containsObject:_hotbarTouch]) {
        int slot = [self hotbarSlotAt:[_hotbarTouch locationInView:self]];
        if (slot >= 0 && slot != _hotbarSlot) [self selectHotbarSlot:slot];
    }
    if (!w || !_primary || ![touches containsObject:_primary]) return;
    gTouchMovedAccepted++;
    CGPoint p = [_primary locationInView:self];
    CGPoint d = CGPointMake(p.x - _lastPrimary.x, p.y - _lastPrimary.y);
    if (hypot(p.x - _startPrimary.x, p.y - _startPrimary.y) > kTapSlop) _moved = YES;
    if (w->cursorMode == GLFW_CURSOR_DISABLED) {
        // Captured cursor (mouse look): relative motion, encoded as a = 1 with the delta in x/y.
        // Scaled to screen pixels like Amethyst (touch point × UIScreen.scale while grabbing),
        // so Minecraft's sensitivity slider feels the same as there.
        const CGFloat k = UIScreen.mainScreen.scale;
        zlPush((ZLEvent){.type = ZLEventCursorPos, .window = H(w), .x = d.x * k, .y = d.y * k, .a = 1});
    } else if (_primaryVirtual) {
        CGSize s = self.bounds.size;
        _virtualCursor.x = MIN(MAX(_virtualCursor.x + d.x, 0), s.width);
        _virtualCursor.y = MIN(MAX(_virtualCursor.y + d.y, 0), s.height);
        self.overlay.pointer.frame = (CGRect){_virtualCursor, self.overlay.pointer.bounds.size};
        [self pushCursor:_virtualCursor];
    } else {
        [self pushCursor:p];
    }
    _lastPrimary = p;
}

- (void)endTouches:(NSSet<UITouch *> *)touches {
    ZLGLFWWindowObj *w = self.owner;
    if (!w) return;
    if (_hotbarTouch && [touches containsObject:_hotbarTouch]) _hotbarTouch = nil;
    if (_primary && [touches containsObject:_primary]) {
        _gestureGeneration++;
        BOOL tap = !_moved && CACurrentMediaTime() - _startTime < kLongPress;
        if (_holding) {
            zlSendButton(w, GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE);
        } else if (tap && _primaryInGame) {
            [zlLightHaptic() impactOccurred];
            zlSendButton(w, GLFW_MOUSE_BUTTON_RIGHT, GLFW_PRESS);
            zlSendButton(w, GLFW_MOUSE_BUTTON_RIGHT, GLFW_RELEASE);
        } else if (tap && _primaryVirtual) {
            [zlLightHaptic() impactOccurred];
            zlSendButton(w, GLFW_MOUSE_BUTTON_LEFT, GLFW_PRESS);
            zlSendButton(w, GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE);
        } else if (!_primaryInGame && !_primaryVirtual) {
            zlSendButton(w, GLFW_MOUSE_BUTTON_LEFT, GLFW_RELEASE);
        }
        _primary = nil;
        _holding = NO;
    }
    if (_secondary && [touches containsObject:_secondary]) {
        zlSendButton(w, GLFW_MOUSE_BUTTON_RIGHT, GLFW_RELEASE);
        _secondary = nil;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    gTouchEnded += (int)touches.count;
    [self endTouches:touches];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    gTouchCancelled += (int)touches.count;
    [self endTouches:touches];
}

- (void)handlePresses:(NSSet<UIPress *> *)presses action:(int)action {
    ZLGLFWWindowObj *w = self.owner;
    if (!w) return;
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (!key) continue;
        int glfwKey = zlKeyFromHID(key.keyCode);
        int mods = zlMods(key.modifierFlags);
        zlPush((ZLEvent){.type = ZLEventKey, .window = H(w), .a = glfwKey, .b = action, .c = mods, .d = (int)key.keyCode});
        if (action == GLFW_PRESS && !(key.modifierFlags & (UIKeyModifierControl | UIKeyModifierCommand))) {
            NSString *chars = key.characters;
            [chars enumerateSubstringsInRange:NSMakeRange(0, chars.length)
                                      options:NSStringEnumerationByComposedCharacterSequences
                                   usingBlock:^(NSString *s, NSRange r, NSRange er, BOOL *stop) {
                UTF32Char cp = 0;
                if ([s getBytes:&cp maxLength:sizeof(cp) usedLength:NULL encoding:NSUTF32LittleEndianStringEncoding
                        options:0 range:NSMakeRange(0, s.length) remainingRange:NULL] && cp >= 32 && cp != 127) {
                    zlPush((ZLEvent){.type = ZLEventChar, .window = H(w), .a = (int)cp, .c = mods});
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
    self.overlay.frame = self.bounds;
    ZLGLFWWindowObj *w = self.owner;
    if (!w) return;
    CGSize s = self.bounds.size;
    if (CGPointEqualToPoint(_virtualCursor, CGPointZero)) _virtualCursor = CGPointMake(s.width / 2, s.height / 2);
    int pw = (int)lround(s.width * w->scale), ph = (int)lround(s.height * w->scale);
    if ((int)s.width != w->width || (int)s.height != w->height) {
        zlPush((ZLEvent){.type = ZLEventWindowSize, .window = H(w), .a = (int)s.width, .b = (int)s.height});
    }
    if (pw != w->fbWidth || ph != w->fbHeight) {
        zlPush((ZLEvent){.type = ZLEventFramebufferSize, .window = H(w), .a = pw, .b = ph});
    }
}

@end

@interface ZLGLFWViewController : UIViewController
@property (nonatomic, strong) ZLGLFWView *glView;
@end

@implementation ZLGLFWViewController
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

static void zlResetHints(void);

ZLAPI int glfwInit(void) {
    if (gInitialized) return GLFW_TRUE;
    if (!zlLoadEGL()) return GLFW_FALSE;
    mach_timebase_info(&gTimebase);
    gTimerBase = mach_absolute_time();
    gTimerOffset = 0;
    gWindows = [NSMutableArray array];
    __block CGSize px;
    __block int fps;
    zlOnMain(^{
        UIScreen *screen = UIScreen.mainScreen;
        CGSize n = screen.nativeBounds.size;  // portrait pixels
        px = CGSizeMake(MAX(n.width, n.height), MIN(n.width, n.height));  // report landscape
        fps = (int)screen.maximumFramesPerSecond;
    });
    gVideoMode = (GLFWvidmode){.width = (int)px.width, .height = (int)px.height,
                               .redBits = 8, .greenBits = 8, .blueBits = 8, .refreshRate = fps};
    zlResetHints();
    gInitialized = YES;
    NSLog(@"[ZLGLFW] initialised: ANGLE Metal display, screen %dx%d @%d Hz", gVideoMode.width, gVideoMode.height, fps);
    return GLFW_TRUE;
}

ZLAPI void glfwTerminate(void) {
    if (!gInitialized) return;
    for (ZLGLFWWindowObj *w in [gWindows copy]) glfwDestroyWindow(H(w));
    gInitialized = NO;
}

ZLAPI void glfwInitHint(int hint, int value) {}
ZLAPI void glfwInitAllocator(const GLFWallocator *allocator) {}

ZLAPI void glfwGetVersion(int *major, int *minor, int *rev) {
    if (major) *major = GLFW_VERSION_MAJOR;
    if (minor) *minor = GLFW_VERSION_MINOR;
    if (rev) *rev = GLFW_VERSION_REVISION;
}

ZLAPI const char *glfwGetVersionString(void) { return "3.4.0 Zalith iOS (UIKit + ANGLE/EGL)"; }

ZLAPI int glfwGetError(const char **description) {
    int code = gLastError;
    if (description) *description = code ? gLastErrorDescription : NULL;
    gLastError = GLFW_NO_ERROR;
    return code;
}

ZLAPI GLFWerrorfun glfwSetErrorCallback(GLFWerrorfun callback) {
    GLFWerrorfun prev = gErrorCallback;
    gErrorCallback = callback;
    return prev;
}

ZLAPI int glfwGetPlatform(void) { return GLFW_PLATFORM_NULL; }
ZLAPI int glfwPlatformSupported(int platform) { return platform == GLFW_PLATFORM_NULL; }

#pragma mark - Monitors

ZLAPI GLFWmonitor **glfwGetMonitors(int *count) {
    if (count) *count = 1;
    return gMonitorList;
}
ZLAPI GLFWmonitor *glfwGetPrimaryMonitor(void) { return &gMonitor; }
ZLAPI void glfwGetMonitorPos(GLFWmonitor *m, int *x, int *y) { if (x) *x = 0; if (y) *y = 0; }
ZLAPI void glfwGetMonitorWorkarea(GLFWmonitor *m, int *x, int *y, int *w, int *h) {
    if (x) *x = 0;
    if (y) *y = 0;
    if (w) *w = gVideoMode.width;
    if (h) *h = gVideoMode.height;
}
ZLAPI void glfwGetMonitorPhysicalSize(GLFWmonitor *m, int *wmm, int *hmm) {
    // ~460 ppi class panel; only used for DPI heuristics.
    if (wmm) *wmm = (int)lround(gVideoMode.width / 460.0 * 25.4);
    if (hmm) *hmm = (int)lround(gVideoMode.height / 460.0 * 25.4);
}
ZLAPI void glfwGetMonitorContentScale(GLFWmonitor *m, float *xs, float *ys) {
    __block float s;
    zlOnMain(^{ s = (float)UIScreen.mainScreen.nativeScale; });
    if (xs) *xs = s;
    if (ys) *ys = s;
}
ZLAPI const char *glfwGetMonitorName(GLFWmonitor *m) { return "iPhone Display"; }
ZLAPI void glfwSetMonitorUserPointer(GLFWmonitor *m, void *p) { gMonitorUserPointer = p; }
ZLAPI void *glfwGetMonitorUserPointer(GLFWmonitor *m) { return gMonitorUserPointer; }
ZLAPI GLFWmonitorfun glfwSetMonitorCallback(GLFWmonitorfun cb) {
    GLFWmonitorfun prev = gMonitorCallback;
    gMonitorCallback = cb;
    return prev;
}
ZLAPI const GLFWvidmode *glfwGetVideoModes(GLFWmonitor *m, int *count) {
    if (count) *count = 1;
    return &gVideoMode;
}
ZLAPI const GLFWvidmode *glfwGetVideoMode(GLFWmonitor *m) { return &gVideoMode; }
ZLAPI void glfwSetGamma(GLFWmonitor *m, float gamma) {}
ZLAPI const GLFWgammaramp *glfwGetGammaRamp(GLFWmonitor *m) {
    zlError(GLFW_FEATURE_UNAVAILABLE, "gamma ramps are not available on iOS");
    return NULL;
}
ZLAPI void glfwSetGammaRamp(GLFWmonitor *m, const GLFWgammaramp *ramp) {}

#pragma mark - Window hints

#define HINT(h) gHints[(h) - 0x20000]

static void zlResetHints(void) {
    memset(gHints, 0, sizeof(gHints));
    HINT(GLFW_VISIBLE) = GLFW_TRUE;
    HINT(GLFW_FOCUSED) = GLFW_TRUE;
    HINT(GLFW_CLIENT_API) = GLFW_OPENGL_API;
    HINT(GLFW_CONTEXT_VERSION_MAJOR) = 1;
    HINT(GLFW_CONTEXT_VERSION_MINOR) = 0;
    HINT(GLFW_OPENGL_PROFILE) = GLFW_OPENGL_ANY_PROFILE;
}

ZLAPI void glfwDefaultWindowHints(void) { zlResetHints(); }

ZLAPI void glfwWindowHint(int hint, int value) {
    if (hint >= 0x20000 && hint < 0x20000 + (int)(sizeof(gHints) / sizeof(gHints[0]))) HINT(hint) = value;
}

ZLAPI void glfwWindowHintString(int hint, const char *value) {}

#pragma mark - Windows

static EGLContext zlCreateContext(EGLContext share) {
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
static UIBackgroundTaskIdentifier gBackgroundTask;
static BOOL gHasBackgroundTask;

static void zlEndBackgroundTask(void) {
    if (!gHasBackgroundTask) return;
    gHasBackgroundTask = NO;
    [UIApplication.sharedApplication endBackgroundTask:gBackgroundTask];
}

static void zlInstallLifecycleObservers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        NSOperationQueue *main = NSOperationQueue.mainQueue;
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            ZLGLFWWindowObj *w = gVisibleWindow;
            if (!w) return;
            zlPush((ZLEvent){.type = ZLEventFocus, .window = H(w), .a = GLFW_FALSE});
            BOOL inGame = w->cursorMode == GLFW_CURSOR_DISABLED;
            if (inGame) {
                zlSendKey(w, GLFW_KEY_ESCAPE, GLFW_PRESS);
                zlSendKey(w, GLFW_KEY_ESCAPE, GLFW_RELEASE);
            }
            NSLog(@"[ZLGLFW] app resigning active: focus lost%s", inGame ? ", sent ESC to pause and save" : "");
        }];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            if (!gVisibleWindow || gHasBackgroundTask) return;
            gBackgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Minecraft save"
                                                                        expirationHandler:^{ zlEndBackgroundTask(); }];
            gHasBackgroundTask = gBackgroundTask != UIBackgroundTaskInvalid;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ zlEndBackgroundTask(); });
            NSLog(@"[ZLGLFW] app in background: holding a background task for 8 s");
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            zlEndBackgroundTask();
            ZLGLFWWindowObj *w = gVisibleWindow;
            if (!w) return;
            zlPush((ZLEvent){.type = ZLEventFocus, .window = H(w), .a = GLFW_TRUE});
            NSLog(@"[ZLGLFW] app active again: focus regained");
        }];
    });
}

ZLAPI GLFWwindow *glfwCreateWindow(int width, int height, const char *title, GLFWmonitor *monitor, GLFWwindow *share) {
    if (!gInitialized) {
        zlError(GLFW_NOT_INITIALIZED, "glfwCreateWindow before glfwInit");
        return NULL;
    }
    ZLGLFWWindowObj *w = [ZLGLFWWindowObj new];
    w.title = title ? @(title) : @"";
    w->hintMajor = HINT(GLFW_CONTEXT_VERSION_MAJOR);
    w->hintMinor = HINT(GLFW_CONTEXT_VERSION_MINOR);
    w->hintProfile = HINT(GLFW_OPENGL_PROFILE);
    w->hintForward = HINT(GLFW_OPENGL_FORWARD_COMPAT);
    w->hintClientAPI = HINT(GLFW_CLIENT_API);
    w->cursorMode = GLFW_CURSOR_NORMAL;
    w->focused = YES;
    // Only one on-screen window; others (e.g. hidden helper contexts) are offscreen.
    w->offscreen = gVisibleWindow != nil || !HINT(GLFW_VISIBLE);

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
        zlOnMain(^{
            UIWindowScene *scene = nil;
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
            }
            ZLGLFWView *view = [[ZLGLFWView alloc] initWithFrame:UIScreen.mainScreen.bounds];
            view.owner = w;
            view.multipleTouchEnabled = YES;
            ZLControlsOverlay *overlay = [[ZLControlsOverlay alloc] initWithOwner:w];
            overlay.gameView = view;
            overlay.multipleTouchEnabled = YES;
            view.overlay = overlay;
            [view addSubview:overlay];
            view.backgroundColor = UIColor.blackColor;
            // Render-resolution scale: ZALITH_RENDER_SCALE (default 1.0 = native pixels).
            const char *rs = getenv("ZALITH_RENDER_SCALE");
            double renderScale = rs ? atof(rs) : 1.0;
            if (renderScale <= 0.1 || renderScale > 1.0) renderScale = 1.0;
            w->scale = (float)(UIScreen.mainScreen.nativeScale * renderScale);
            view.contentScaleFactor = w->scale;
            ZLGLFWViewController *vc = [ZLGLFWViewController new];
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
                        NSLog(@"[ZLGLFW] landscape request failed: %@", error);
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
            surface = p_eglCreateWindowSurface(gDisplay, gWindowConfig, (__bridge EGLNativeWindowType)view.layer, NULL);
        });
        w->surface = surface;
        w->visible = YES;
        gVisibleWindow = w;
        zlInstallLifecycleObservers();
    }
    if (w->surface == EGL_NO_SURFACE) {
        zlError(GLFW_PLATFORM_ERROR, "EGL surface creation failed: 0x%X", p_eglGetError());
        if (gVisibleWindow == w) gVisibleWindow = nil;
        zlOnMain(^{ w.uiWindow.hidden = YES; });
        return NULL;
    }
    w->context = zlCreateContext(share ? W(share)->context : EGL_NO_CONTEXT);
    if (w->context == EGL_NO_CONTEXT) {
        zlError(GLFW_VERSION_UNAVAILABLE, "EGL context creation failed: 0x%X", p_eglGetError());
        p_eglDestroySurface(gDisplay, w->surface);
        if (gVisibleWindow == w) gVisibleWindow = nil;
        zlOnMain(^{ w.uiWindow.hidden = YES; });
        return NULL;
    }
    EGLint ew = 0, eh = 0;
    p_eglQuerySurface(gDisplay, w->surface, EGL_WIDTH, &ew);
    p_eglQuerySurface(gDisplay, w->surface, EGL_HEIGHT, &eh);
    if (ew > 0 && eh > 0) { w->fbWidth = ew; w->fbHeight = eh; }
    [gWindows addObject:w];
    NSLog(@"[ZLGLFW] window \"%@\" %s: %dx%d pt, framebuffer %dx%d px (requested %dx%d, GL %d.%d profile 0x%X)",
          w.title, w->offscreen ? "offscreen" : "on-screen", w->width, w->height, w->fbWidth, w->fbHeight,
          width, height, w->hintMajor, w->hintMinor, w->hintProfile);
    return H(w);
}

ZLAPI void glfwDestroyWindow(GLFWwindow *window) {
    if (!window) return;
    ZLGLFWWindowObj *w = W(window);
    if (tCurrent == w) {
        p_eglMakeCurrent(gDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        tCurrent = nil;
    }
    if (w->context) p_eglDestroyContext(gDisplay, w->context);
    if (w->surface) p_eglDestroySurface(gDisplay, w->surface);
    w->context = EGL_NO_CONTEXT;
    w->surface = EGL_NO_SURFACE;
    if (gVisibleWindow == w) gVisibleWindow = nil;
    if (!w->offscreen) {
        NSLog(@"[ZLGLFW] touches: began=%d moved=%d movedAccepted=%d ended=%d cancelled=%d hotbarSelects=%d",
              gTouchBegan, gTouchMoved, gTouchMovedAccepted, gTouchEnded, gTouchCancelled, gHotbarSelects);
    }
    zlOnMain(^{
        w.view.owner = nil;
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

ZLAPI int glfwWindowShouldClose(GLFWwindow *window) { return window && W(window)->shouldClose; }
ZLAPI void glfwSetWindowShouldClose(GLFWwindow *window, int value) { if (window) W(window)->shouldClose = value != 0; }
ZLAPI void glfwSetWindowTitle(GLFWwindow *window, const char *title) { if (window && title) W(window).title = @(title); }
ZLAPI void glfwSetWindowIcon(GLFWwindow *window, int count, const GLFWimage *images) {}
ZLAPI void glfwGetWindowPos(GLFWwindow *window, int *x, int *y) { if (x) *x = 0; if (y) *y = 0; }
ZLAPI void glfwSetWindowPos(GLFWwindow *window, int x, int y) {}
ZLAPI void glfwGetWindowSize(GLFWwindow *window, int *width, int *height) {
    if (width) *width = window ? W(window)->width : 0;
    if (height) *height = window ? W(window)->height : 0;
}
ZLAPI void glfwSetWindowSizeLimits(GLFWwindow *window, int minw, int minh, int maxw, int maxh) {}
ZLAPI void glfwSetWindowAspectRatio(GLFWwindow *window, int numer, int denom) {}
ZLAPI void glfwSetWindowSize(GLFWwindow *window, int width, int height) {}  // always full screen
ZLAPI void glfwGetFramebufferSize(GLFWwindow *window, int *width, int *height) {
    if (width) *width = window ? W(window)->fbWidth : 0;
    if (height) *height = window ? W(window)->fbHeight : 0;
}
ZLAPI void glfwGetWindowFrameSize(GLFWwindow *window, int *l, int *t, int *r, int *b) {
    if (l) *l = 0; if (t) *t = 0; if (r) *r = 0; if (b) *b = 0;
}
ZLAPI void glfwGetWindowContentScale(GLFWwindow *window, float *xs, float *ys) {
    float s = window ? W(window)->scale : 1;
    if (xs) *xs = s;
    if (ys) *ys = s;
}
ZLAPI float glfwGetWindowOpacity(GLFWwindow *window) { return 1.0f; }
ZLAPI void glfwSetWindowOpacity(GLFWwindow *window, float opacity) {}
ZLAPI void glfwIconifyWindow(GLFWwindow *window) {}
ZLAPI void glfwRestoreWindow(GLFWwindow *window) {}
ZLAPI void glfwMaximizeWindow(GLFWwindow *window) {}
ZLAPI void glfwShowWindow(GLFWwindow *window) {
    if (!window || W(window)->offscreen) return;
    ZLGLFWWindowObj *w = W(window);
    w->visible = YES;
    zlOnMain(^{ w.uiWindow.hidden = NO; });
}
ZLAPI void glfwHideWindow(GLFWwindow *window) {
    if (!window || W(window)->offscreen) return;
    ZLGLFWWindowObj *w = W(window);
    w->visible = NO;
    zlOnMain(^{ w.uiWindow.hidden = YES; });
}
ZLAPI void glfwFocusWindow(GLFWwindow *window) {}
ZLAPI void glfwRequestWindowAttention(GLFWwindow *window) {}
ZLAPI GLFWmonitor *glfwGetWindowMonitor(GLFWwindow *window) {
    return window && !W(window)->offscreen ? &gMonitor : NULL;
}
ZLAPI void glfwSetWindowMonitor(GLFWwindow *window, GLFWmonitor *monitor, int x, int y, int w, int h, int refresh) {}

ZLAPI int glfwGetWindowAttrib(GLFWwindow *window, int attrib) {
    if (!window) return 0;
    ZLGLFWWindowObj *w = W(window);
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
ZLAPI void glfwSetWindowAttrib(GLFWwindow *window, int attrib, int value) {}
ZLAPI void glfwSetWindowUserPointer(GLFWwindow *window, void *pointer) { if (window) W(window)->userPointer = pointer; }
ZLAPI void *glfwGetWindowUserPointer(GLFWwindow *window) { return window ? W(window)->userPointer : NULL; }

#define SETCB(field, type)                       \
    if (!window) return NULL;                    \
    ZLGLFWWindowObj *w = W(window);              \
    type prev = w->field;                        \
    w->field = callback;                         \
    return prev;

ZLAPI GLFWwindowposfun glfwSetWindowPosCallback(GLFWwindow *window, GLFWwindowposfun callback) { SETCB(posCB, GLFWwindowposfun) }
ZLAPI GLFWwindowsizefun glfwSetWindowSizeCallback(GLFWwindow *window, GLFWwindowsizefun callback) { SETCB(sizeCB, GLFWwindowsizefun) }
ZLAPI GLFWwindowclosefun glfwSetWindowCloseCallback(GLFWwindow *window, GLFWwindowclosefun callback) { SETCB(closeCB, GLFWwindowclosefun) }
ZLAPI GLFWwindowrefreshfun glfwSetWindowRefreshCallback(GLFWwindow *window, GLFWwindowrefreshfun callback) { SETCB(refreshCB, GLFWwindowrefreshfun) }
ZLAPI GLFWwindowfocusfun glfwSetWindowFocusCallback(GLFWwindow *window, GLFWwindowfocusfun callback) { SETCB(focusCB, GLFWwindowfocusfun) }
ZLAPI GLFWwindowiconifyfun glfwSetWindowIconifyCallback(GLFWwindow *window, GLFWwindowiconifyfun callback) { SETCB(iconifyCB, GLFWwindowiconifyfun) }
ZLAPI GLFWwindowmaximizefun glfwSetWindowMaximizeCallback(GLFWwindow *window, GLFWwindowmaximizefun callback) { SETCB(maximizeCB, GLFWwindowmaximizefun) }
ZLAPI GLFWframebuffersizefun glfwSetFramebufferSizeCallback(GLFWwindow *window, GLFWframebuffersizefun callback) { SETCB(fbCB, GLFWframebuffersizefun) }
ZLAPI GLFWwindowcontentscalefun glfwSetWindowContentScaleCallback(GLFWwindow *window, GLFWwindowcontentscalefun callback) { SETCB(scaleCB, GLFWwindowcontentscalefun) }
ZLAPI GLFWkeyfun glfwSetKeyCallback(GLFWwindow *window, GLFWkeyfun callback) { SETCB(keyCB, GLFWkeyfun) }
ZLAPI GLFWcharfun glfwSetCharCallback(GLFWwindow *window, GLFWcharfun callback) { SETCB(charCB, GLFWcharfun) }
ZLAPI GLFWcharmodsfun glfwSetCharModsCallback(GLFWwindow *window, GLFWcharmodsfun callback) { SETCB(charModsCB, GLFWcharmodsfun) }
ZLAPI GLFWmousebuttonfun glfwSetMouseButtonCallback(GLFWwindow *window, GLFWmousebuttonfun callback) { SETCB(mouseCB, GLFWmousebuttonfun) }
ZLAPI GLFWcursorposfun glfwSetCursorPosCallback(GLFWwindow *window, GLFWcursorposfun callback) { SETCB(cursorCB, GLFWcursorposfun) }
ZLAPI GLFWcursorenterfun glfwSetCursorEnterCallback(GLFWwindow *window, GLFWcursorenterfun callback) { SETCB(enterCB, GLFWcursorenterfun) }
ZLAPI GLFWscrollfun glfwSetScrollCallback(GLFWwindow *window, GLFWscrollfun callback) { SETCB(scrollCB, GLFWscrollfun) }
ZLAPI GLFWdropfun glfwSetDropCallback(GLFWwindow *window, GLFWdropfun callback) { SETCB(dropCB, GLFWdropfun) }

#pragma mark - Event processing

static BOOL zlWindowAlive(void *window) {
    for (ZLGLFWWindowObj *w in gWindows) if (H(w) == window) return YES;
    return NO;
}

static void zlDispatch(ZLEvent e) {
    if (!zlWindowAlive(e.window)) return;
    ZLGLFWWindowObj *w = W(e.window);
    GLFWwindow *h = e.window;
    switch (e.type) {
        case ZLEventCursorPos:
            if (e.a == 1) {  // relative (captured cursor)
                w->cursorX += e.x;
                w->cursorY += e.y;
            } else {
                w->cursorX = e.x;
                w->cursorY = e.y;
            }
            if (w->cursorCB) w->cursorCB(h, w->cursorX, w->cursorY);
            break;
        case ZLEventMouseButton:
            if (e.a >= 0 && e.a <= GLFW_MOUSE_BUTTON_LAST) w->buttons[e.a] = (char)e.b;
            if (w->mouseCB) w->mouseCB(h, e.a, e.b, 0);
            break;
        case ZLEventScroll:
            if (w->scrollCB) w->scrollCB(h, e.x, e.y);
            break;
        case ZLEventKey:
            if (e.a >= 0 && e.a <= GLFW_KEY_LAST) {
                int action = e.b;
                if (action == GLFW_PRESS && w->keys[e.a] == GLFW_PRESS) action = GLFW_REPEAT;
                w->keys[e.a] = (char)(e.b == GLFW_RELEASE ? GLFW_RELEASE : GLFW_PRESS);
                if (w->keyCB) w->keyCB(h, e.a, e.d, action, e.c);
            } else if (w->keyCB) {
                w->keyCB(h, GLFW_KEY_UNKNOWN, e.d, e.b, e.c);
            }
            break;
        case ZLEventChar:
            if (w->charCB) w->charCB(h, (unsigned int)e.a);
            if (w->charModsCB) w->charModsCB(h, (unsigned int)e.a, e.c);
            break;
        case ZLEventFramebufferSize:
            w->fbWidth = e.a;
            w->fbHeight = e.b;
            if (w->fbCB) w->fbCB(h, e.a, e.b);
            break;
        case ZLEventWindowSize:
            w->width = e.a;
            w->height = e.b;
            if (w->sizeCB) w->sizeCB(h, e.a, e.b);
            break;
        case ZLEventClose:
            w->shouldClose = YES;
            if (w->closeCB) w->closeCB(h);
            break;
        case ZLEventFocus:
            w->focused = e.a != 0;
            if (w->focusCB) w->focusCB(h, e.a);
            break;
    }
}

static void zlDrain(void) {
    pthread_mutex_lock(&gEventLock);
    size_t n = gEventCount;
    ZLEvent *batch = n ? malloc(n * sizeof(ZLEvent)) : NULL;
    if (n) memcpy(batch, gEvents, n * sizeof(ZLEvent));
    gEventCount = 0;
    gEmptyEventPosted = NO;
    pthread_mutex_unlock(&gEventLock);
    for (size_t i = 0; i < n; i++) zlDispatch(batch[i]);
    free(batch);
}

ZLAPI void glfwPollEvents(void) { zlDrain(); }

static void zlWait(double timeout) {
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
    zlDrain();
}

ZLAPI void glfwWaitEvents(void) { zlWait(-1); }
ZLAPI void glfwWaitEventsTimeout(double timeout) { zlWait(timeout > 0 ? timeout : 0); }
ZLAPI void glfwPostEmptyEvent(void) {
    pthread_mutex_lock(&gEventLock);
    gEmptyEventPosted = YES;
    pthread_cond_signal(&gEventCond);
    pthread_mutex_unlock(&gEventLock);
}

#pragma mark - Input state

ZLAPI int glfwGetInputMode(GLFWwindow *window, int mode) {
    if (!window) return 0;
    ZLGLFWWindowObj *w = W(window);
    switch (mode) {
        case GLFW_CURSOR: return w->cursorMode;
        case GLFW_STICKY_KEYS: return w->stickyKeys;
        case GLFW_STICKY_MOUSE_BUTTONS: return w->stickyMouse;
        case GLFW_LOCK_KEY_MODS: return w->lockKeyMods;
        case GLFW_RAW_MOUSE_MOTION: return w->rawMotion;
        default: return 0;
    }
}

ZLAPI void glfwSetInputMode(GLFWwindow *window, int mode, int value) {
    if (!window) return;
    ZLGLFWWindowObj *w = W(window);
    switch (mode) {
        case GLFW_CURSOR:
            if (w->cursorMode != value) {
                NSLog(@"[ZLGLFW] cursor mode 0x%X", value);
                // On-screen game controls only while the game captures the cursor.
                BOOL inGame = value == GLFW_CURSOR_DISABLED;
                ZLControlsOverlay *overlay = w.view.overlay;
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

ZLAPI int glfwRawMouseMotionSupported(void) { return GLFW_TRUE; }

ZLAPI const char *glfwGetKeyName(int key, int scancode) {
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

ZLAPI int glfwGetKeyScancode(int key) {
    for (long usage = 0; usage < 0xE8; usage++) if (zlKeyFromHID(usage) == key && key != GLFW_KEY_UNKNOWN) return (int)usage;
    return -1;
}

ZLAPI int glfwGetKey(GLFWwindow *window, int key) {
    if (!window || key < 0 || key > GLFW_KEY_LAST) return GLFW_RELEASE;
    return W(window)->keys[key] ? GLFW_PRESS : GLFW_RELEASE;
}

ZLAPI int glfwGetMouseButton(GLFWwindow *window, int button) {
    if (!window || button < 0 || button > GLFW_MOUSE_BUTTON_LAST) return GLFW_RELEASE;
    return W(window)->buttons[button] ? GLFW_PRESS : GLFW_RELEASE;
}

ZLAPI void glfwGetCursorPos(GLFWwindow *window, double *x, double *y) {
    if (x) *x = window ? W(window)->cursorX : 0;
    if (y) *y = window ? W(window)->cursorY : 0;
}

ZLAPI void glfwSetCursorPos(GLFWwindow *window, double x, double y) {
    if (!window) return;
    W(window)->cursorX = x;
    W(window)->cursorY = y;
}

struct GLFWcursor { int shape; };

ZLAPI GLFWcursor *glfwCreateCursor(const GLFWimage *image, int xhot, int yhot) {
    struct GLFWcursor *c = calloc(1, sizeof(*c));
    return c;
}
ZLAPI GLFWcursor *glfwCreateStandardCursor(int shape) {
    struct GLFWcursor *c = calloc(1, sizeof(*c));
    c->shape = shape;
    return c;
}
ZLAPI void glfwDestroyCursor(GLFWcursor *cursor) { free(cursor); }
ZLAPI void glfwSetCursor(GLFWwindow *window, GLFWcursor *cursor) {}

#pragma mark - Joysticks (none yet)

ZLAPI int glfwJoystickPresent(int jid) { return GLFW_FALSE; }
ZLAPI const float *glfwGetJoystickAxes(int jid, int *count) { if (count) *count = 0; return NULL; }
ZLAPI const unsigned char *glfwGetJoystickButtons(int jid, int *count) { if (count) *count = 0; return NULL; }
ZLAPI const unsigned char *glfwGetJoystickHats(int jid, int *count) { if (count) *count = 0; return NULL; }
ZLAPI const char *glfwGetJoystickName(int jid) { return NULL; }
ZLAPI const char *glfwGetJoystickGUID(int jid) { return NULL; }
ZLAPI void glfwSetJoystickUserPointer(int jid, void *pointer) {}
ZLAPI void *glfwGetJoystickUserPointer(int jid) { return NULL; }
ZLAPI int glfwJoystickIsGamepad(int jid) { return GLFW_FALSE; }
ZLAPI GLFWjoystickfun glfwSetJoystickCallback(GLFWjoystickfun callback) {
    GLFWjoystickfun prev = gJoystickCallback;
    gJoystickCallback = callback;
    return prev;
}
ZLAPI int glfwUpdateGamepadMappings(const char *string) { return GLFW_TRUE; }
ZLAPI const char *glfwGetGamepadName(int jid) { return NULL; }
ZLAPI int glfwGetGamepadState(int jid, GLFWgamepadstate *state) { return GLFW_FALSE; }

#pragma mark - Clipboard

ZLAPI void glfwSetClipboardString(GLFWwindow *window, const char *string) {
    NSString *s = string ? @(string) : @"";
    zlOnMain(^{ UIPasteboard.generalPasteboard.string = s; });
}

ZLAPI const char *glfwGetClipboardString(GLFWwindow *window) {
    __block NSString *s = nil;
    zlOnMain(^{ s = UIPasteboard.generalPasteboard.string; });
    gClipboard = s ?: @"";
    free(gClipboardC);
    gClipboardC = strdup(gClipboard.UTF8String);
    return gClipboardC;
}

#pragma mark - Time

static double zlNow(void) {
    uint64_t t = mach_absolute_time() - gTimerBase;
    return (double)t * gTimebase.numer / gTimebase.denom / 1e9;
}

ZLAPI double glfwGetTime(void) { return gInitialized ? zlNow() - gTimerOffset : 0; }
ZLAPI void glfwSetTime(double time) { gTimerOffset = zlNow() - time; }
ZLAPI uint64_t glfwGetTimerValue(void) { return mach_absolute_time(); }
ZLAPI uint64_t glfwGetTimerFrequency(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (uint64_t)(1e9 * tb.denom / tb.numer);
}

#pragma mark - Context

ZLAPI void glfwMakeContextCurrent(GLFWwindow *window) {
    if (!gInitialized) return;
    ZLGLFWWindowObj *w = window ? W(window) : nil;
    BOOL ok = w ? p_eglMakeCurrent(gDisplay, w->surface, w->surface, w->context)
                : p_eglMakeCurrent(gDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (!ok) {
        zlError(GLFW_PLATFORM_ERROR, "eglMakeCurrent failed: 0x%X", p_eglGetError());
        return;
    }
    tCurrent = w;
}

ZLAPI GLFWwindow *glfwGetCurrentContext(void) { return tCurrent ? H(tCurrent) : NULL; }

ZLAPI void glfwSwapBuffers(GLFWwindow *window) {
    if (!window) return;
    ZLGLFWWindowObj *w = W(window);
    if (!p_eglSwapBuffers(gDisplay, w->surface)) {
        zlError(GLFW_PLATFORM_ERROR, "eglSwapBuffers failed: 0x%X", p_eglGetError());
    }
}

ZLAPI void glfwSwapInterval(int interval) {
    if (gInitialized && p_eglSwapInterval) p_eglSwapInterval(gDisplay, interval);
}

// Desktop GL entry points come from MobileGlues when it has been loaded (LWJGL
// loads it as its OpenGL library); otherwise fall back to ANGLE's GLES ones.
static void *zlMobileGlues(void) {
    static void *mg;
    if (!mg) {
        NSString *p = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libmobileglues.dylib"];
        mg = dlopen(p.fileSystemRepresentation, RTLD_NOLOAD | RTLD_LAZY | RTLD_LOCAL);
    }
    return mg;
}

ZLAPI GLFWglproc glfwGetProcAddress(const char *procname) {
    void *mg = zlMobileGlues();
    void *p = mg ? dlsym(mg, procname) : NULL;
    if (!p && p_eglGetProcAddress) p = (void *)p_eglGetProcAddress(procname);
    return (GLFWglproc)p;
}

ZLAPI int glfwExtensionSupported(const char *extension) {
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
ZLAPI uint32_t glfwGetCocoaMonitor(GLFWmonitor *monitor) { return 0; }
ZLAPI void *glfwGetCocoaWindow(GLFWwindow *window) { return NULL; }
ZLAPI void *glfwGetNSGLContext(GLFWwindow *window) { return NULL; }
ZLAPI EGLDisplay glfwGetEGLDisplay(void) { return gDisplay; }
ZLAPI EGLContext glfwGetEGLContext(GLFWwindow *window) { return window ? W(window)->context : EGL_NO_CONTEXT; }
ZLAPI EGLSurface glfwGetEGLSurface(GLFWwindow *window) { return window ? W(window)->surface : EGL_NO_SURFACE; }
ZLAPI EGLConfig glfwGetEGLConfig(GLFWwindow *window) {
    if (!window) return NULL;
    return W(window)->offscreen ? gPbufferConfig : gWindowConfig;
}

#pragma mark - App-facing helpers

NSString *ZLGLFWLibraryPath(void) { return NSBundle.mainBundle.executablePath; }

NSString *ZLGLFWSelfCheck(void) {
    // LWJGL dlopen()s this path and dlsym()s every glfw* function from it.
    void *h = dlopen(ZLGLFWLibraryPath().fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
    if (!h) return [NSString stringWithFormat:@"dlopen(executable) FAILED: %s", dlerror()];
    void *init = dlsym(h, "glfwInit");
    void *swap = dlsym(h, "glfwSwapBuffers");
    return [NSString stringWithFormat:@"dlopen(executable) ok; glfwInit=%s glfwSwapBuffers=%s",
            init == (void *)glfwInit ? "ok" : (init ? "different address" : "missing"),
            swap == (void *)glfwSwapBuffers ? "ok" : (swap ? "different address" : "missing")];
}
