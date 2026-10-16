// Milestone 6 step 1: OpenGL ES 3 through ANGLE (Metal backend) on a
// CAMetalLayer, with pixel read-back so the result is verified, not eyeballed.
// ANGLE is loaded with dlopen so the app still runs if it is not bundled.

#import "GLTest.h"
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

#define EGL_EGL_PROTOTYPES 0
#define GL_GLES_PROTOTYPES 0
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>

static const int kFramesToRender = 120;

static NSString *libEGLPath(void) {
    NSString *fw = NSBundle.mainBundle.privateFrameworksPath;
    for (NSString *rel in @[@"libEGL.framework/libEGL", @"libEGL.dylib"]) {
        NSString *p = [fw stringByAppendingPathComponent:rel];
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) return p;
    }
    return nil;
}

BOOL ZLGLTestRuntimeBundled(void) { return libEGLPath() != nil; }

@interface ZLMetalLayerView : UIView
@end
@implementation ZLMetalLayerView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

@implementation ZLGLTestViewController {
    ZLMetalLayerView *_glView;
    UILabel *_label;
    CADisplayLink *_link;
    NSMutableString *_report;
    BOOL _finished;
    int _frames;
    CFTimeInterval _startTime;
    BOOL _pixelsOK;

    void *_lib;
    EGLDisplay _dpy;
    EGLSurface _surface;
    EGLContext _ctx;
    GLuint _program, _vbo, _vao;
    EGLint _width, _height;

    PFNEGLGETPROCADDRESSPROC eglGetProcAddress_;
    PFNEGLGETERRORPROC eglGetError_;
    PFNEGLMAKECURRENTPROC eglMakeCurrent_;
    PFNEGLSWAPBUFFERSPROC eglSwapBuffers_;
    PFNEGLDESTROYSURFACEPROC eglDestroySurface_;
    PFNEGLDESTROYCONTEXTPROC eglDestroyContext_;
    PFNEGLTERMINATEPROC eglTerminate_;

    PFNGLGETSTRINGPROC glGetString_;
    PFNGLGETERRORPROC glGetError_;
    PFNGLVIEWPORTPROC glViewport_;
    PFNGLCLEARCOLORPROC glClearColor_;
    PFNGLCLEARPROC glClear_;
    PFNGLUSEPROGRAMPROC glUseProgram_;
    PFNGLBINDVERTEXARRAYPROC glBindVertexArray_;
    PFNGLDRAWARRAYSPROC glDrawArrays_;
    PFNGLREADPIXELSPROC glReadPixels_;
    PFNGLFINISHPROC glFinish_;
}

- (void)log:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1, 2) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[GLTest] %@", line);
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

- (void)viewDidLoad {
    [super viewDidLoad];
    _report = [NSMutableString string];
    self.view.backgroundColor = UIColor.blackColor;
    _glView = [[ZLMetalLayerView alloc] initWithFrame:self.view.bounds];
    _glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _glView.contentScaleFactor = UIScreen.mainScreen.nativeScale;
    [self.view addSubview:_glView];

    _label = [[UILabel alloc] init];
    _label.numberOfLines = 0;
    _label.textColor = UIColor.whiteColor;
    _label.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_label];
    [NSLayoutConstraint activateConstraints:@[
        [_label.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [_label.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [_label.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
    ]];
    _label.text = @"Starting OpenGL ES test…";
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_link || _finished) return;
    [self log:@"===== GL test %@", [[NSISO8601DateFormatter new] stringFromDate:NSDate.date]];
    if (![self setUpEGL]) {
        [self finish:NO];
        return;
    }
    if (![self setUpScene]) {
        [self finish:NO];
        return;
    }
    _startTime = CACurrentMediaTime();
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

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

- (BOOL)setUpEGL {
    NSString *path = libEGLPath();
    if (!path) {
        [self log:@"ANGLE libEGL not found in %@", NSBundle.mainBundle.privateFrameworksPath];
        return NO;
    }
    _lib = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!_lib) {
        [self log:@"dlopen(%@) failed: %s", path, dlerror()];
        return NO;
    }
    [self log:@"loaded %@", path.lastPathComponent];

    eglGetProcAddress_ = (PFNEGLGETPROCADDRESSPROC)dlsym(_lib, "eglGetProcAddress");
    eglGetError_ = [self egl:"eglGetError"];
    PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay = [self egl:"eglGetPlatformDisplayEXT"];
    PFNEGLINITIALIZEPROC initialize = [self egl:"eglInitialize"];
    PFNEGLQUERYSTRINGPROC queryString = [self egl:"eglQueryString"];
    PFNEGLBINDAPIPROC bindAPI = [self egl:"eglBindAPI"];
    PFNEGLCHOOSECONFIGPROC chooseConfig = [self egl:"eglChooseConfig"];
    PFNEGLCREATEWINDOWSURFACEPROC createWindowSurface = [self egl:"eglCreateWindowSurface"];
    PFNEGLCREATECONTEXTPROC createContext = [self egl:"eglCreateContext"];
    PFNEGLQUERYSURFACEPROC querySurface = [self egl:"eglQuerySurface"];
    eglMakeCurrent_ = [self egl:"eglMakeCurrent"];
    eglSwapBuffers_ = [self egl:"eglSwapBuffers"];
    eglDestroySurface_ = [self egl:"eglDestroySurface"];
    eglDestroyContext_ = [self egl:"eglDestroyContext"];
    eglTerminate_ = [self egl:"eglTerminate"];
    if (!eglGetProcAddress_ || !getPlatformDisplay || !initialize || !chooseConfig || !createWindowSurface ||
        !createContext || !eglMakeCurrent_ || !eglSwapBuffers_) {
        return NO;
    }

    EGLint displayAttrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
    _dpy = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, displayAttrs);
    EGLint major = 0, minor = 0;
    if (_dpy == EGL_NO_DISPLAY || !initialize(_dpy, &major, &minor)) {
        [self log:@"eglInitialize failed: 0x%X", eglGetError_ ? eglGetError_() : 0];
        return NO;
    }
    [self log:@"EGL %d.%d vendor=%s version=%s", major, minor, queryString(_dpy, EGL_VENDOR), queryString(_dpy, EGL_VERSION)];
    [self log:@"EGL client APIs: %s", queryString(_dpy, EGL_CLIENT_APIS)];

    if (!bindAPI(EGL_OPENGL_ES_API)) {
        [self log:@"eglBindAPI(ES) failed: 0x%X", eglGetError_()];
        return NO;
    }
    EGLint configAttrs[] = {
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_NONE,
    };
    EGLConfig config;
    EGLint count = 0;
    if (!chooseConfig(_dpy, configAttrs, &config, 1, &count) || count < 1) {
        [self log:@"eglChooseConfig found no ES3 window config: 0x%X", eglGetError_()];
        return NO;
    }
    CAMetalLayer *layer = (CAMetalLayer *)_glView.layer;
    _surface = createWindowSurface(_dpy, config, (__bridge EGLNativeWindowType)layer, NULL);
    if (_surface == EGL_NO_SURFACE) {
        [self log:@"eglCreateWindowSurface failed: 0x%X", eglGetError_()];
        return NO;
    }
    EGLint ctxAttrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
    _ctx = createContext(_dpy, config, EGL_NO_CONTEXT, ctxAttrs);
    if (_ctx == EGL_NO_CONTEXT || !eglMakeCurrent_(_dpy, _surface, _surface, _ctx)) {
        [self log:@"context creation/makeCurrent failed: 0x%X", eglGetError_()];
        return NO;
    }
    querySurface(_dpy, _surface, EGL_WIDTH, &_width);
    querySurface(_dpy, _surface, EGL_HEIGHT, &_height);

    glGetString_ = [self gl:"glGetString"];
    glGetError_ = [self gl:"glGetError"];
    glViewport_ = [self gl:"glViewport"];
    glClearColor_ = [self gl:"glClearColor"];
    glClear_ = [self gl:"glClear"];
    glUseProgram_ = [self gl:"glUseProgram"];
    glBindVertexArray_ = [self gl:"glBindVertexArray"];
    glDrawArrays_ = [self gl:"glDrawArrays"];
    glReadPixels_ = [self gl:"glReadPixels"];
    glFinish_ = [self gl:"glFinish"];
    if (!glGetString_ || !glClear_ || !glDrawArrays_ || !glReadPixels_) return NO;

    [self log:@"GL_VENDOR=%s", glGetString_(GL_VENDOR)];
    [self log:@"GL_RENDERER=%s", glGetString_(GL_RENDERER)];
    [self log:@"GL_VERSION=%s", glGetString_(GL_VERSION)];
    [self log:@"GL_SHADING_LANGUAGE_VERSION=%s", glGetString_(GL_SHADING_LANGUAGE_VERSION)];
    [self log:@"surface %dx%d", _width, _height];
    return YES;
}

- (GLuint)compile:(GLenum)type source:(const char *)src {
    PFNGLCREATESHADERPROC createShader = [self gl:"glCreateShader"];
    PFNGLSHADERSOURCEPROC shaderSource = [self gl:"glShaderSource"];
    PFNGLCOMPILESHADERPROC compileShader = [self gl:"glCompileShader"];
    PFNGLGETSHADERIVPROC getShaderiv = [self gl:"glGetShaderiv"];
    PFNGLGETSHADERINFOLOGPROC getShaderInfoLog = [self gl:"glGetShaderInfoLog"];
    GLuint s = createShader(type);
    shaderSource(s, 1, &src, NULL);
    compileShader(s);
    GLint ok = 0;
    getShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char info[1024] = {0};
        getShaderInfoLog(s, sizeof(info), NULL, info);
        [self log:@"shader compile failed: %s", info];
        return 0;
    }
    return s;
}

- (BOOL)setUpScene {
    const char *vs =
        "#version 300 es\n"
        "layout(location = 0) in vec2 pos;\n"
        "void main() { gl_Position = vec4(pos, 0.0, 1.0); }\n";
    const char *fs =
        "#version 300 es\n"
        "precision mediump float;\n"
        "out vec4 color;\n"
        "void main() { color = vec4(1.0, 0.5, 0.0, 1.0); }\n";
    GLuint v = [self compile:GL_VERTEX_SHADER source:vs];
    GLuint f = [self compile:GL_FRAGMENT_SHADER source:fs];
    if (!v || !f) return NO;
    PFNGLCREATEPROGRAMPROC createProgram = [self gl:"glCreateProgram"];
    PFNGLATTACHSHADERPROC attachShader = [self gl:"glAttachShader"];
    PFNGLLINKPROGRAMPROC linkProgram = [self gl:"glLinkProgram"];
    PFNGLGETPROGRAMIVPROC getProgramiv = [self gl:"glGetProgramiv"];
    PFNGLGENVERTEXARRAYSPROC genVertexArrays = [self gl:"glGenVertexArrays"];
    PFNGLGENBUFFERSPROC genBuffers = [self gl:"glGenBuffers"];
    PFNGLBINDBUFFERPROC bindBuffer = [self gl:"glBindBuffer"];
    PFNGLBUFFERDATAPROC bufferData = [self gl:"glBufferData"];
    PFNGLENABLEVERTEXATTRIBARRAYPROC enableAttrib = [self gl:"glEnableVertexAttribArray"];
    PFNGLVERTEXATTRIBPOINTERPROC attribPointer = [self gl:"glVertexAttribPointer"];

    _program = createProgram();
    attachShader(_program, v);
    attachShader(_program, f);
    linkProgram(_program);
    GLint linked = 0;
    getProgramiv(_program, GL_LINK_STATUS, &linked);
    if (!linked) {
        [self log:@"program link failed"];
        return NO;
    }
    // Large triangle covering the screen centre, leaving corners uncovered.
    const GLfloat verts[] = {-0.8f, -0.8f, 0.8f, -0.8f, 0.0f, 0.8f};
    genVertexArrays(1, &_vao);
    glBindVertexArray_(_vao);
    genBuffers(1, &_vbo);
    bindBuffer(GL_ARRAY_BUFFER, _vbo);
    bufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
    enableAttrib(0);
    attribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
    GLenum err = glGetError_();
    if (err != GL_NO_ERROR) [self log:@"glGetError after setup: 0x%X", err];
    return err == GL_NO_ERROR;
}

static BOOL near(const GLubyte *px, int r, int g, int b) {
    return abs(px[0] - r) <= 3 && abs(px[1] - g) <= 3 && abs(px[2] - b) <= 3;
}

- (void)frame:(CADisplayLink *)link {
    glViewport_(0, 0, _width, _height);
    glClearColor_(0.1f, 0.3f, 0.6f, 1.0f);
    glClear_(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glUseProgram_(_program);
    glBindVertexArray_(_vao);
    glDrawArrays_(GL_TRIANGLES, 0, 3);
    _frames++;

    if (_frames == kFramesToRender) {
        glFinish_();
        GLubyte centre[4] = {0}, corner[4] = {0};
        glReadPixels_(_width / 2, _height / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, centre);
        glReadPixels_(4, 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, corner);
        GLenum err = glGetError_();
        // Expected: triangle (255,128,0) at the centre, clear colour (26,77,153) in the corner.
        _pixelsOK = err == GL_NO_ERROR && near(centre, 255, 128, 0) && near(corner, 26, 77, 153);
        [self log:@"read-back centre=(%d,%d,%d,%d) corner=(%d,%d,%d,%d) glError=0x%X",
                  centre[0], centre[1], centre[2], centre[3], corner[0], corner[1], corner[2], corner[3], err];
    }
    if (!eglSwapBuffers_(_dpy, _surface)) {
        [self log:@"eglSwapBuffers failed at frame %d: 0x%X", _frames, eglGetError_()];
        [self finish:NO];
        return;
    }
    if (_frames >= kFramesToRender) {
        CFTimeInterval dt = CACurrentMediaTime() - _startTime;
        [self log:@"rendered %d frames in %.2fs (%.1f fps)", _frames, dt, _frames / dt];
        [self finish:_pixelsOK];
    }
}

- (void)finish:(BOOL)ok {
    if (_finished) return;
    _finished = YES;
    [_link invalidate];
    _link = nil;
    [self log:ok ? @"ZALITH_GL_OK" : @"GL test FAILED"];
    if (_dpy) {
        eglMakeCurrent_(_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (_ctx) eglDestroyContext_(_dpy, _ctx);
        if (_surface) eglDestroySurface_(_dpy, _surface);
        eglTerminate_(_dpy);
        _dpy = EGL_NO_DISPLAY;
    }
    _label.text = _report;
    if (self.onFinish) self.onFinish(ok, [_report copy]);
}

@end
