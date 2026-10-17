package io.github.voxelium;

import org.lwjgl.egl.EGL;
import org.lwjgl.egl.EGLCapabilities;
import org.lwjgl.opengles.GLES;
import org.lwjgl.opengles.GLESCapabilities;
import org.lwjgl.system.Configuration;
import org.lwjgl.system.JNI;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.Platform;
import org.lwjgl.Version;

import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import org.lwjgl.PointerBuffer;

import static org.lwjgl.egl.EGL10.*;
import static org.lwjgl.egl.EGL12.eglBindAPI;
import static org.lwjgl.egl.EGL12.EGL_RENDERABLE_TYPE;
import static org.lwjgl.egl.EGL14.EGL_OPENGL_ES_API;
import static org.lwjgl.egl.EGL15.EGL_CONTEXT_MAJOR_VERSION;
import static org.lwjgl.egl.EGL15.EGL_CONTEXT_MINOR_VERSION;
import static org.lwjgl.egl.EGL15.EGL_OPENGL_ES3_BIT;
import static org.lwjgl.opengles.GLES30.*;
import static org.lwjgl.system.MemoryUtil.NULL;
import static org.lwjgl.system.MemoryUtil.memAddress;

/**
 * Milestone 6 step 2: Java → LWJGL → ANGLE (OpenGL ES 3 on Metal), offscreen.
 * args[0] = path to libEGL, args[1] = path to libGLESv2.
 */
public final class LwjglGlesSmokeTest {
    // ANGLE's EGL_ANGLE_platform_angle values (EGL/eglext_angle.h).
    private static final int EGL_PLATFORM_ANGLE_ANGLE = 0x3202;
    private static final int EGL_PLATFORM_ANGLE_TYPE_ANGLE = 0x3203;
    private static final int EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE = 0x3489;
    private static final int SIZE = 256;

    public static void main(String[] args) {
        System.out.println("LWJGL " + Version.getVersion() + " platform=" + Platform.get() + " arch=" + Platform.getArchitecture());
        Configuration.EGL_LIBRARY_NAME.set(args[0]);
        Configuration.OPENGLES_LIBRARY_NAME.set(args[1]);
        // EGL loads itself in its static initializer unless told otherwise;
        // load it explicitly so failures point at this line.
        Configuration.EGL_EXPLICIT_INIT.set(true);

        EGL.create();
        EGLCapabilities client = EGL.createDisplayCapabilities(EGL_NO_DISPLAY);
        if (!client.EGL_EXT_platform_base) throw new IllegalStateException("EGL_EXT_platform_base missing");

        try (MemoryStack stack = MemoryStack.stackPush()) {
            IntBuffer displayAttribs = stack.ints(EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE);
            // LWJGL's generated eglGetPlatformDisplay(EXT) wrappers reject a NULL
            // native_display (Checks.check), but EGL_DEFAULT_DISPLAY is NULL and
            // valid for ANGLE. Call the function pointer directly instead.
            long getPlatformDisplay = EGL.getCapabilities().eglGetPlatformDisplayEXT;
            check(getPlatformDisplay != NULL, "eglGetPlatformDisplayEXT lookup");
            long display = JNI.callPPP(EGL_PLATFORM_ANGLE_ANGLE, NULL, memAddress(displayAttribs), getPlatformDisplay);
            IntBuffer major = stack.mallocInt(1), minor = stack.mallocInt(1);
            check(display != EGL_NO_DISPLAY && eglInitialize(display, major, minor), "eglInitialize");
            System.out.println("EGL " + major.get(0) + "." + minor.get(0) + " vendor=" + eglQueryString(display, EGL_VENDOR));
            check(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI");

            IntBuffer configAttribs = stack.ints(
                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE);
            PointerBuffer configs = stack.mallocPointer(1);
            IntBuffer count = stack.mallocInt(1);
            check(eglChooseConfig(display, configAttribs, configs, count) && count.get(0) > 0, "eglChooseConfig");
            long config = configs.get(0);

            long surface = eglCreatePbufferSurface(display, config, stack.ints(EGL_WIDTH, SIZE, EGL_HEIGHT, SIZE, EGL_NONE));
            check(surface != EGL_NO_SURFACE, "eglCreatePbufferSurface");
            long context = eglCreateContext(display, config, EGL_NO_CONTEXT,
                stack.ints(EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE));
            check(context != EGL_NO_CONTEXT && eglMakeCurrent(display, surface, surface, context), "context");

            GLESCapabilities caps = GLES.createCapabilities();
            System.out.println("GL_RENDERER=" + glGetString(GL_RENDERER));
            System.out.println("GL_VERSION=" + glGetString(GL_VERSION) + " GLES30=" + caps.GLES30);

            boolean ok = draw(stack);

            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroyContext(display, context);
            eglDestroySurface(display, surface);
            eglTerminate(display);
            System.out.println(ok ? "VOXELIUM_LWJGL_GLES_OK" : "LWJGL GLES test FAILED");
        }
    }

    private static boolean draw(MemoryStack stack) {
        int program = glCreateProgram();
        glAttachShader(program, shader(GL_VERTEX_SHADER,
            "#version 300 es\nlayout(location = 0) in vec2 pos;\nvoid main() { gl_Position = vec4(pos, 0.0, 1.0); }\n"));
        glAttachShader(program, shader(GL_FRAGMENT_SHADER,
            "#version 300 es\nprecision mediump float;\nout vec4 color;\nvoid main() { color = vec4(1.0, 0.5, 0.0, 1.0); }\n"));
        glLinkProgram(program);
        check(glGetProgrami(program, GL_LINK_STATUS) == GL_TRUE, "link: " + glGetProgramInfoLog(program));

        int vao = glGenVertexArrays();
        glBindVertexArray(vao);
        int vbo = glGenBuffers();
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, stack.floats(-0.8f, -0.8f, 0.8f, -0.8f, 0.0f, 0.8f), GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, false, 0, 0L);

        glViewport(0, 0, SIZE, SIZE);
        glClearColor(0.1f, 0.3f, 0.6f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glUseProgram(program);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glFinish();

        ByteBuffer centre = stack.malloc(4), corner = stack.malloc(4);
        glReadPixels(SIZE / 2, SIZE / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, centre);
        glReadPixels(2, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, corner);
        int err = glGetError();
        System.out.println("read-back centre=" + rgba(centre) + " corner=" + rgba(corner) + " glError=0x" + Integer.toHexString(err));
        return err == GL_NO_ERROR && near(centre, 255, 128, 0) && near(corner, 26, 77, 153);
    }

    private static int shader(int type, String src) {
        int s = glCreateShader(type);
        glShaderSource(s, src);
        glCompileShader(s);
        check(glGetShaderi(s, GL_COMPILE_STATUS) == GL_TRUE, "compile: " + glGetShaderInfoLog(s));
        return s;
    }

    private static String rgba(ByteBuffer b) {
        return "(" + (b.get(0) & 0xFF) + "," + (b.get(1) & 0xFF) + "," + (b.get(2) & 0xFF) + "," + (b.get(3) & 0xFF) + ")";
    }

    private static boolean near(ByteBuffer b, int r, int g, int bl) {
        return Math.abs((b.get(0) & 0xFF) - r) <= 3 && Math.abs((b.get(1) & 0xFF) - g) <= 3 && Math.abs((b.get(2) & 0xFF) - bl) <= 3;
    }

    private static void check(boolean ok, String what) {
        if (!ok) throw new IllegalStateException(what + " failed, eglGetError=0x" + Integer.toHexString(eglGetError()));
    }
}
