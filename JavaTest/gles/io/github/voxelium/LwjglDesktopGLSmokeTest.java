package io.github.voxelium;

import org.lwjgl.PointerBuffer;
import org.lwjgl.Version;
import org.lwjgl.egl.EGL;
import org.lwjgl.opengl.GL;
import org.lwjgl.opengl.GLCapabilities;
import org.lwjgl.system.Configuration;
import org.lwjgl.system.JNI;
import org.lwjgl.system.MemoryStack;

import java.nio.ByteBuffer;
import java.nio.IntBuffer;

import static org.lwjgl.egl.EGL10.*;
import static org.lwjgl.egl.EGL12.eglBindAPI;
import static org.lwjgl.egl.EGL12.EGL_RENDERABLE_TYPE;
import static org.lwjgl.egl.EGL14.EGL_OPENGL_ES_API;
import static org.lwjgl.egl.EGL15.EGL_CONTEXT_MAJOR_VERSION;
import static org.lwjgl.egl.EGL15.EGL_CONTEXT_MINOR_VERSION;
import static org.lwjgl.egl.EGL15.EGL_OPENGL_ES3_BIT;
import static org.lwjgl.opengl.GL33C.*;
import static org.lwjgl.system.MemoryUtil.NULL;
import static org.lwjgl.system.MemoryUtil.memAddress;

/**
 * Milestone 6 step 3c: Java -> LWJGL desktop OpenGL bindings (what Minecraft
 * uses) -> MobileGlues -> ANGLE GLES -> Metal, offscreen.
 *
 * ANGLE provides only an OpenGL ES context, so the context is created with EGL
 * as an ES 3.x context; MobileGlues, loaded as LWJGL's "OpenGL library"
 * (-Dorg.lwjgl.opengl.libname), translates desktop GL calls and GLSL 330 onto it.
 * MobileGlues initialises when loaded and queries GLES, so the context must be
 * current before the GL class is first used.
 *
 * args[0] = path to ANGLE's libEGL.
 */
public final class LwjglDesktopGLSmokeTest {
    private static final int EGL_PLATFORM_ANGLE_ANGLE = 0x3202;
    private static final int EGL_PLATFORM_ANGLE_TYPE_ANGLE = 0x3203;
    private static final int EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE = 0x3489;
    private static final int SIZE = 256;

    public static void main(String[] args) {
        System.out.println("LWJGL " + Version.getVersion() + " opengl.libname=" + System.getProperty("org.lwjgl.opengl.libname"));
        Configuration.EGL_LIBRARY_NAME.set(args[0]);
        Configuration.EGL_EXPLICIT_INIT.set(true);
        EGL.create();

        try (MemoryStack stack = MemoryStack.stackPush()) {
            long getPlatformDisplay = EGL.getCapabilities().eglGetPlatformDisplayEXT;
            check(getPlatformDisplay != NULL, "eglGetPlatformDisplayEXT lookup");
            IntBuffer displayAttribs = stack.ints(EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE);
            long display = JNI.callPPP(EGL_PLATFORM_ANGLE_ANGLE, NULL, memAddress(displayAttribs), getPlatformDisplay);
            IntBuffer major = stack.mallocInt(1), minor = stack.mallocInt(1);
            check(display != EGL_NO_DISPLAY && eglInitialize(display, major, minor), "eglInitialize");
            check(eglBindAPI(EGL_OPENGL_ES_API), "eglBindAPI");

            IntBuffer configAttribs = stack.ints(
                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24,
                EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE);
            PointerBuffer configs = stack.mallocPointer(1);
            IntBuffer count = stack.mallocInt(1);
            check(eglChooseConfig(display, configAttribs, configs, count) && count.get(0) > 0, "eglChooseConfig");
            long config = configs.get(0);

            long surface = eglCreatePbufferSurface(display, config, stack.ints(EGL_WIDTH, SIZE, EGL_HEIGHT, SIZE, EGL_NONE));
            check(surface != EGL_NO_SURFACE, "eglCreatePbufferSurface");
            long context = EGL_NO_CONTEXT;
            for (int esMinor : new int[]{2, 1, 0}) {
                context = eglCreateContext(display, config, EGL_NO_CONTEXT,
                    stack.ints(EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, esMinor, EGL_NONE));
                if (context != EGL_NO_CONTEXT) {
                    System.out.println("ANGLE context: OpenGL ES 3." + esMinor);
                    break;
                }
            }
            check(context != EGL_NO_CONTEXT && eglMakeCurrent(display, surface, surface, context), "context");

            // First use of GL: loads MobileGlues, which initialises against this context.
            GLCapabilities caps = GL.createCapabilities();
            System.out.println("GL_VENDOR=" + glGetString(GL_VENDOR));
            System.out.println("GL_RENDERER=" + glGetString(GL_RENDERER));
            System.out.println("GL_VERSION=" + glGetString(GL_VERSION));
            System.out.println("GL_SHADING_LANGUAGE_VERSION=" + glGetString(GL_SHADING_LANGUAGE_VERSION));
            System.out.println("caps OpenGL32=" + caps.OpenGL32 + " OpenGL33=" + caps.OpenGL33 + " OpenGL40=" + caps.OpenGL40);

            boolean ok = caps.OpenGL33 && draw(stack);

            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroyContext(display, context);
            eglDestroySurface(display, surface);
            eglTerminate(display);
            System.out.println(ok ? "VOXELIUM_LWJGL_DESKTOPGL_OK" : "LWJGL desktop GL test FAILED");
        }
    }

    private static boolean draw(MemoryStack stack) {
        int program = glCreateProgram();
        glAttachShader(program, shader(GL_VERTEX_SHADER,
            "#version 330 core\nlayout(location = 0) in vec2 pos;\nvoid main() { gl_Position = vec4(pos, 0.0, 1.0); }\n"));
        glAttachShader(program, shader(GL_FRAGMENT_SHADER,
            "#version 330 core\nout vec4 color;\nvoid main() { color = vec4(1.0, 0.5, 0.0, 1.0); }\n"));
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
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
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
