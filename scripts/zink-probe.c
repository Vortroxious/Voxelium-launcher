// Zink compute probe (docs/COMPUTE_SHADERS_RESEARCH.md). Creates a desktop GL
// core context through Mesa's EGL (surfaceless platform, Zink), logs the GL
// version, renderer and compute-related extensions, then runs a compute shader
// that writes an SSBO and reads it back.
//
// Used on the build Mac by `scripts/build-zink.sh mac` to check the Zink stack
// before it goes to a phone; the iOS test (App/Voxelium/Native) does the same.
//   cc zink-probe.c -o zink-probe; ./zink-probe <dir with libEGL>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mach/mach.h>
#include <unistd.h>

#define EGL_EGL_PROTOTYPES 0
typedef void *EGLDisplay, *EGLConfig, *EGLContext, *EGLSurface;
typedef int EGLint;
typedef unsigned EGLBoolean, EGLenum;
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#define EGL_NONE 0x3038
#define EGL_OPENGL_API 0x30A2
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_OPENGL_BIT 0x0008
#define EGL_SURFACE_TYPE 0x3033
#define EGL_PBUFFER_BIT 0x0001
#define EGL_WIDTH 0x3057
#define EGL_HEIGHT 0x3056
#define EGL_CONTEXT_MAJOR_VERSION 0x3098
#define EGL_CONTEXT_MINOR_VERSION 0x30FB
#define EGL_CONTEXT_OPENGL_PROFILE_MASK 0x30FD
#define EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT 0x0001
#define EGL_VENDOR 0x3053
#define EGL_VERSION 0x3054
#define EGL_EXTENSIONS 0x3055

typedef unsigned GLenum, GLuint, GLbitfield;
typedef int GLint, GLsizei;
typedef long GLsizeiptr, GLintptr;
typedef char GLchar;
typedef unsigned char GLubyte;
#define GL_VENDOR 0x1F00
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02
#define GL_EXTENSIONS 0x1F03
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define GL_NUM_EXTENSIONS 0x821D
#define GL_MAJOR_VERSION 0x821B
#define GL_MINOR_VERSION 0x821C
#define GL_COMPUTE_SHADER 0x91B9
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_SHADER_STORAGE_BUFFER 0x90D2
#define GL_DYNAMIC_READ 0x88E9
#define GL_MAP_READ_BIT 0x0001
#define GL_SHADER_STORAGE_BARRIER_BIT 0x00002000
#define GL_BUFFER_UPDATE_BARRIER_BIT 0x00000200
#define GL_MAX_COMPUTE_WORK_GROUP_COUNT 0x91BE
#define GL_MAX_COMPUTE_WORK_GROUP_SIZE 0x91BF

#define N 1024

static void *egl, *(*gpa)(const char *);
#define LOAD(name) name##_ = (__typeof__(name##_))gpa(#name)
static void *eglsym(const char *n) { void *p = dlsym(egl, n); return p ? p : gpa(n); }

// The figure iOS's memory limit (jetsam) is measured against.
static double footprint_mb(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return info.phys_footprint / 1048576.0;
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *dir = argc > 1 ? argv[1] : ".";
    char path[4096];
    snprintf(path, sizeof path, "%s/libEGL.dylib", dir);
    if (!getenv("GALLIUM_DRIVER")) setenv("GALLIUM_DRIVER", "zink", 1);
    egl = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!egl) { printf("PROBE_FAIL dlopen %s: %s\n", path, dlerror()); return 1; }
    gpa = (void *(*)(const char *))dlsym(egl, "eglGetProcAddress");

    EGLDisplay (*eglGetPlatformDisplay_)(EGLenum, void *, const intptr_t *) = eglsym("eglGetPlatformDisplay");
    EGLBoolean (*eglInitialize_)(EGLDisplay, EGLint *, EGLint *) = eglsym("eglInitialize");
    const char *(*eglQueryString_)(EGLDisplay, EGLint) = eglsym("eglQueryString");
    EGLBoolean (*eglBindAPI_)(EGLenum) = eglsym("eglBindAPI");
    EGLBoolean (*eglChooseConfig_)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *) = eglsym("eglChooseConfig");
    EGLSurface (*eglCreatePbufferSurface_)(EGLDisplay, EGLConfig, const EGLint *) = eglsym("eglCreatePbufferSurface");
    EGLContext (*eglCreateContext_)(EGLDisplay, EGLConfig, EGLContext, const EGLint *) = eglsym("eglCreateContext");
    EGLBoolean (*eglMakeCurrent_)(EGLDisplay, EGLSurface, EGLSurface, EGLContext) = eglsym("eglMakeCurrent");
    EGLint (*eglGetError_)(void) = eglsym("eglGetError");

    printf("footprint before EGL: %.1f MB\n", footprint_mb());
    double t0 = now_ms();
    EGLDisplay dpy = eglGetPlatformDisplay_(EGL_PLATFORM_SURFACELESS_MESA, NULL, NULL);
    EGLint maj = 0, min = 0;
    if (!dpy || !eglInitialize_(dpy, &maj, &min)) { printf("PROBE_FAIL eglInitialize 0x%x\n", eglGetError_()); return 1; }
    printf("EGL %d.%d vendor=%s version=%s\n", maj, min, eglQueryString_(dpy, EGL_VENDOR), eglQueryString_(dpy, EGL_VERSION));
    eglBindAPI_(EGL_OPENGL_API);
    const EGLint cfg_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
    EGLConfig cfg = NULL;
    EGLint ncfg = 0;
    if (!eglChooseConfig_(dpy, cfg_attrs, &cfg, 1, &ncfg) || ncfg < 1) { printf("PROBE_FAIL eglChooseConfig 0x%x\n", eglGetError_()); return 1; }
    const EGLint pb[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    EGLSurface surf = eglCreatePbufferSurface_(dpy, cfg, pb);
    EGLContext ctx = NULL;
    static const int versions[][2] = {{4, 6}, {4, 5}, {4, 3}, {4, 2}, {4, 1}, {3, 3}, {3, 2}};
    for (unsigned i = 0; i < sizeof versions / sizeof versions[0] && !ctx; i++) {
        const EGLint ca[] = {EGL_CONTEXT_MAJOR_VERSION, versions[i][0], EGL_CONTEXT_MINOR_VERSION, versions[i][1],
                             EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
        ctx = eglCreateContext_(dpy, cfg, NULL, ca);
        if (ctx) printf("context: requested %d.%d core\n", versions[i][0], versions[i][1]);
    }
    if (!ctx) {
        printf("no core context (0x%x); trying a default (compatibility) context\n", eglGetError_());
        const EGLint none[] = {EGL_NONE};
        ctx = eglCreateContext_(dpy, cfg, NULL, none);
    }
    if (!ctx) { printf("PROBE_FAIL eglCreateContext 0x%x\n", eglGetError_()); return 1; }
    if (!eglMakeCurrent_(dpy, surf, surf, ctx)) { printf("PROBE_FAIL eglMakeCurrent 0x%x\n", eglGetError_()); return 1; }
    printf("context ready in %.1f ms\n", now_ms() - t0);
    printf("footprint after context: %.1f MB\n", footprint_mb());

    const GLubyte *(*glGetString_)(GLenum);
    const GLubyte *(*glGetStringi_)(GLenum, GLuint);
    void (*glGetIntegerv_)(GLenum, GLint *);
    void (*glGetIntegeri_v_)(GLenum, GLuint, GLint *);
    GLuint (*glCreateShader_)(GLenum);
    void (*glShaderSource_)(GLuint, GLsizei, const GLchar *const *, const GLint *);
    void (*glCompileShader_)(GLuint);
    void (*glGetShaderiv_)(GLuint, GLenum, GLint *);
    void (*glGetShaderInfoLog_)(GLuint, GLsizei, GLsizei *, GLchar *);
    GLuint (*glCreateProgram_)(void);
    void (*glAttachShader_)(GLuint, GLuint);
    void (*glLinkProgram_)(GLuint);
    void (*glGetProgramiv_)(GLuint, GLenum, GLint *);
    void (*glGetProgramInfoLog_)(GLuint, GLsizei, GLsizei *, GLchar *);
    void (*glUseProgram_)(GLuint);
    void (*glGenBuffers_)(GLsizei, GLuint *);
    void (*glBindBuffer_)(GLenum, GLuint);
    void (*glBufferData_)(GLenum, GLsizeiptr, const void *, GLenum);
    void (*glBindBufferBase_)(GLenum, GLuint, GLuint);
    void (*glDispatchCompute_)(GLuint, GLuint, GLuint);
    void (*glMemoryBarrier_)(GLbitfield);
    void *(*glMapBufferRange_)(GLenum, GLintptr, GLsizeiptr, GLbitfield);
    unsigned char (*glUnmapBuffer_)(GLenum);
    void (*glFinish_)(void);
    GLenum (*glGetError_)(void);
    LOAD(glGetString); LOAD(glGetStringi); LOAD(glGetIntegerv); LOAD(glGetIntegeri_v);
    LOAD(glCreateShader); LOAD(glShaderSource); LOAD(glCompileShader); LOAD(glGetShaderiv); LOAD(glGetShaderInfoLog);
    LOAD(glCreateProgram); LOAD(glAttachShader); LOAD(glLinkProgram); LOAD(glGetProgramiv); LOAD(glGetProgramInfoLog);
    LOAD(glUseProgram); LOAD(glGenBuffers); LOAD(glBindBuffer); LOAD(glBufferData); LOAD(glBindBufferBase);
    LOAD(glDispatchCompute); LOAD(glMemoryBarrier); LOAD(glMapBufferRange); LOAD(glUnmapBuffer);
    LOAD(glFinish); LOAD(glGetError);

    GLint glmaj = 0, glmin = 0, next = 0;
    glGetIntegerv_(GL_MAJOR_VERSION, &glmaj);
    glGetIntegerv_(GL_MINOR_VERSION, &glmin);
    glGetIntegerv_(GL_NUM_EXTENSIONS, &next);
    if (!glmaj) /* GL_MAJOR_VERSION is GL 3.0+; read a 2.x version from the string */
        sscanf((const char *)glGetString_(GL_VERSION), "%d.%d", &glmaj, &glmin);
    printf("GL_VERSION=%s\nGL_RENDERER=%s\nGL_VENDOR=%s\nGL_SHADING_LANGUAGE_VERSION=%s\nextensions=%d\n",
           glGetString_(GL_VERSION), glGetString_(GL_RENDERER), glGetString_(GL_VENDOR),
           glGetString_(GL_SHADING_LANGUAGE_VERSION), next);
    static const char *wanted[] = {"GL_ARB_compute_shader", "GL_ARB_shader_storage_buffer_object",
                                   "GL_ARB_shader_image_load_store", "GL_ARB_geometry_shader4",
                                   "GL_ARB_tessellation_shader", "GL_ARB_transform_feedback3",
                                   "GL_ARB_multi_draw_indirect", "GL_ARB_gpu_shader5"};
    for (unsigned w = 0; w < sizeof wanted / sizeof wanted[0]; w++) {
        int found = 0;
        for (GLint i = 0; i < next && !found; i++) found = !strcmp((const char *)glGetStringi_(GL_EXTENSIONS, i), wanted[w]);
        if (!next) { /* compatibility contexts below 3.0 have no glGetStringi list */
            const char *all = (const char *)glGetString_(GL_EXTENSIONS), *p = all;
            size_t n = strlen(wanted[w]);
            while (p && (p = strstr(p, wanted[w])) && !found) {
                found = (p == all || p[-1] == ' ') && (p[n] == ' ' || p[n] == 0);
                p += n;
            }
        }
        printf("  %s: %s\n", wanted[w], found ? "yes" : "no");
    }
    if (getenv("PROBE_ALL_EXTENSIONS")) {
        for (GLint i = 0; i < next; i++) printf("  ext %s\n", glGetStringi_(GL_EXTENSIONS, i));
        if (!next) printf("  extensions: %s\n", glGetString_(GL_EXTENSIONS));
    }
    int core43 = glmaj > 4 || (glmaj == 4 && glmin >= 3);
    GLint wg[3] = {0}, wgs[3] = {0};
    for (int i = 0; i < 3; i++) {
        glGetIntegeri_v_(GL_MAX_COMPUTE_WORK_GROUP_COUNT, i, &wg[i]);
        glGetIntegeri_v_(GL_MAX_COMPUTE_WORK_GROUP_SIZE, i, &wgs[i]);
    }
    printf("GL %d.%d core43=%d max_work_group_count=%d,%d,%d max_work_group_size=%d,%d,%d\n",
           glmaj, glmin, core43, wg[0], wg[1], wg[2], wgs[0], wgs[1], wgs[2]);

    if (!core43) {
        /* Not even attempted: a #version 430 shader cannot compile here, and Mesa's
         * disk cache can wrongly report one cached by a 4.6 run as compiled. */
        printf("compute skipped: GL %d.%d (%s)\n", glmaj, glmin, glGetString_(GL_VERSION));
        printf("footprint after context checks: %.1f MB\n", footprint_mb());
        return 0;
    }
    const char *src =
        "#version 430 core\n"
        "layout(local_size_x = 64) in;\n"
        "layout(std430, binding = 0) buffer Out { uint v[]; };\n"
        "void main() { uint i = gl_GlobalInvocationID.x; v[i] = i * 3u + 1u; }\n";
    double tc = now_ms();
    GLuint sh = glCreateShader_(GL_COMPUTE_SHADER);
    glShaderSource_(sh, 1, &src, NULL);
    glCompileShader_(sh);
    GLint ok = 0;
    char log[2048] = "";
    glGetShaderiv_(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) { glGetShaderInfoLog_(sh, sizeof log, NULL, log); printf("PROBE_FAIL compute compile: %s\n", log); return 2; }
    GLuint prog = glCreateProgram_();
    glAttachShader_(prog, sh);
    glLinkProgram_(prog);
    glGetProgramiv_(prog, GL_LINK_STATUS, &ok);
    if (!ok) { glGetProgramInfoLog_(prog, sizeof log, NULL, log); printf("PROBE_FAIL compute link: %s\n", log); return 2; }
    printf("compute compile+link %.1f ms\n", now_ms() - tc);

    GLuint buf;
    glGenBuffers_(1, &buf);
    glBindBuffer_(GL_SHADER_STORAGE_BUFFER, buf);
    glBufferData_(GL_SHADER_STORAGE_BUFFER, N * 4, NULL, GL_DYNAMIC_READ);
    glBindBufferBase_(GL_SHADER_STORAGE_BUFFER, 0, buf);
    glUseProgram_(prog);
    double td = now_ms();
    glDispatchCompute_(N / 64, 1, 1);
    glMemoryBarrier_(GL_SHADER_STORAGE_BARRIER_BIT | GL_BUFFER_UPDATE_BARRIER_BIT);
    glFinish_();
    printf("dispatch+finish %.2f ms\n", now_ms() - td);
    const unsigned *v = glMapBufferRange_(GL_SHADER_STORAGE_BUFFER, 0, N * 4, GL_MAP_READ_BIT);
    if (!v) { printf("PROBE_FAIL map 0x%x\n", glGetError_()); return 2; }
    for (unsigned i = 0; i < N; i++)
        if (v[i] != i * 3u + 1u) { printf("PROBE_FAIL mismatch at %u: %u != %u\n", i, v[i], i * 3u + 1u); return 3; }
    glUnmapBuffer_(GL_SHADER_STORAGE_BUFFER);
    printf("gl error after test: 0x%x\n", glGetError_());
    printf("VOXELIUM_ZINK_COMPUTE_OK (%d values read back)\n", N);
    printf("footprint after compute: %.1f MB\n", footprint_mb());

    // Frame time: a full-screen pass with some per-pixel work into an FBO the size
    // of an iPhone 15 Pro Max screen (1290x2796), finished every frame.
    void (*glGenFramebuffers_)(GLsizei, GLuint *);
    void (*glBindFramebuffer_)(GLenum, GLuint);
    void (*glGenTextures_)(GLsizei, GLuint *);
    void (*glBindTexture_)(GLenum, GLuint);
    void (*glTexStorage2D_)(GLenum, GLsizei, GLenum, GLsizei, GLsizei);
    void (*glFramebufferTexture2D_)(GLenum, GLenum, GLenum, GLuint, GLint);
    GLenum (*glCheckFramebufferStatus_)(GLenum);
    void (*glViewport_)(GLint, GLint, GLsizei, GLsizei);
    void (*glGenVertexArrays_)(GLsizei, GLuint *);
    void (*glBindVertexArray_)(GLuint);
    void (*glDrawArrays_)(GLenum, GLint, GLsizei);
    void (*glUniform1f_)(GLint, float);
    GLint (*glGetUniformLocation_)(GLuint, const GLchar *);
    void (*glReadPixels_)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
    LOAD(glGenFramebuffers); LOAD(glBindFramebuffer); LOAD(glGenTextures); LOAD(glBindTexture);
    LOAD(glTexStorage2D); LOAD(glFramebufferTexture2D); LOAD(glCheckFramebufferStatus); LOAD(glViewport);
    LOAD(glGenVertexArrays); LOAD(glBindVertexArray); LOAD(glDrawArrays); LOAD(glUniform1f);
    LOAD(glGetUniformLocation); LOAD(glReadPixels);
    const int W = 1290, H = 2796;
    GLuint tex, fbo, vao;
    glGenTextures_(1, &tex);
    glBindTexture_(0x0DE1 /* GL_TEXTURE_2D */, tex);
    glTexStorage2D_(0x0DE1, 1, 0x8058 /* GL_RGBA8 */, W, H);
    glGenFramebuffers_(1, &fbo);
    glBindFramebuffer_(0x8D40 /* GL_FRAMEBUFFER */, fbo);
    glFramebufferTexture2D_(0x8D40, 0x8CE0 /* COLOR_ATTACHMENT0 */, 0x0DE1, tex, 0);
    if (glCheckFramebufferStatus_(0x8D40) != 0x8CD5) { printf("PROBE_FAIL framebuffer incomplete\n"); return 4; }
    const char *vs = "#version 330 core\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);"
                     "gl_Position=vec4(p*2.0-1.0,0.0,1.0);}\n";
    const char *fs = "#version 330 core\nuniform float t;out vec4 c;void main(){vec2 u=gl_FragCoord.xy/vec2(1290.0,2796.0);"
                     "float a=0.0;for(int i=0;i<16;i++)a+=sin(u.x*float(i)+t)*cos(u.y*float(i)-t);"
                     "c=vec4(u,0.5+0.03*a,1.0);}\n";
    const char *srcs[2] = {vs, fs};
    GLenum kinds[2] = {0x8B31 /* VERTEX */, 0x8B30 /* FRAGMENT */};
    GLuint rp = glCreateProgram_();
    for (int k = 0; k < 2; k++) {
        GLuint x = glCreateShader_(kinds[k]);
        glShaderSource_(x, 1, &srcs[k], NULL);
        glCompileShader_(x);
        glGetShaderiv_(x, GL_COMPILE_STATUS, &ok);
        if (!ok) { glGetShaderInfoLog_(x, sizeof log, NULL, log); printf("PROBE_FAIL draw shader: %s\n", log); return 4; }
        glAttachShader_(rp, x);
    }
    glLinkProgram_(rp);
    glGetProgramiv_(rp, GL_LINK_STATUS, &ok);
    if (!ok) { glGetProgramInfoLog_(rp, sizeof log, NULL, log); printf("PROBE_FAIL draw link: %s\n", log); return 4; }
    glUseProgram_(rp);
    GLint tl = glGetUniformLocation_(rp, "t");
    glGenVertexArrays_(1, &vao);
    glBindVertexArray_(vao);
    glViewport_(0, 0, W, H);
    // PROBE_FRAMES=n runs longer, printing the footprint every 300 frames, to tell
    // a leak (steady growth) from a pool that fills once.
    const int frames = getenv("PROBE_FRAMES") ? atoi(getenv("PROBE_FRAMES")) : 300;
    // PROBE_FLUSH_ONLY=1 ends frames with glFlush, so nothing waits for the GPU.
    const int flush_only = getenv("PROBE_FLUSH_ONLY") != NULL;
    void (*glFlush_)(void);
    LOAD(glFlush);
    // PROBE_FENCED=1: a fence per frame, waiting for the one two frames back, as
    // swap throttling does in a game.
    const int fenced = getenv("PROBE_FENCED") != NULL;
    void *(*glFenceSync_)(GLenum, GLbitfield);
    GLenum (*glClientWaitSync_)(void *, GLbitfield, unsigned long long);
    void (*glDeleteSync_)(void *);
    LOAD(glFenceSync); LOAD(glClientWaitSync); LOAD(glDeleteSync);
    void *fences[2] = {0};
    double first = 0, tf = now_ms();
    for (int f = 0; f < frames; f++) {
        double t1 = now_ms();
        glUniform1f_(tl, f * 0.01f);
        glDrawArrays_(0x0004 /* GL_TRIANGLES */, 0, 3);
        if (fenced) {
            void **slot = &fences[f % 2];
            if (*slot) { glClientWaitSync_(*slot, 0x1 /* FLUSH_COMMANDS */, 1000000000ull); glDeleteSync_(*slot); }
            *slot = glFenceSync_(0x9117 /* GPU_COMMANDS_COMPLETE */, 0);
            glFlush_();
        } else if (flush_only && f > 0) glFlush_(); else glFinish_();
        if (f == 0) first = now_ms() - t1;
        if ((frames > 300 && (f + 1) % 300 == 0) || ((flush_only || fenced) && frames <= 300 && (f + 1) % 50 == 0)) printf("  frame %d: footprint %.1f MB\n", f + 1, footprint_mb());
    }
    if (flush_only) {
        double tw = now_ms();
        glFinish_();
        printf("flush-only: final glFinish waited %.1f ms; footprint %.1f MB\n", now_ms() - tw, footprint_mb());
    }
    double total = now_ms() - tf;
    unsigned char px[4] = {0};
    glReadPixels_(W / 2, H / 2, 1, 1, 0x1908 /* GL_RGBA */, 0x1401 /* UNSIGNED_BYTE */, px);
    printf("frames: %d at %dx%d, first %.1f ms, mean %.2f ms (excluding first: %.2f ms), centre pixel %u,%u,%u,%u, gl error 0x%x\n",
           frames, W, H, first, total / frames, (total - first) / (frames - 1), px[0], px[1], px[2], px[3], glGetError_());
    printf("footprint after frames: %.1f MB\n", footprint_mb());
    if (flush_only) { // is the memory freed late, or reused by frames that wait?
        sleep(1);
        printf("flush-only: 1 s later footprint %.1f MB\n", footprint_mb());
        for (int f = 0; f < 300; f++) {
            glUniform1f_(tl, f * 0.01f);
            glDrawArrays_(0x0004, 0, 3);
            glFinish_();
        }
        printf("flush-only: after 300 more finish-each frames footprint %.1f MB\n", footprint_mb());
    }
    if (getenv("PROBE_HOLD_S")) { // keep the process alive for vmmap/heap
        printf("holding pid %d\n", getpid());
        sleep((unsigned)atoi(getenv("PROBE_HOLD_S")));
    }
    return 0;
}
