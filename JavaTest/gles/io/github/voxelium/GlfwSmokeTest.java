package io.github.voxelium;

import org.lwjgl.Version;
import org.lwjgl.glfw.GLFWErrorCallback;
import org.lwjgl.opengl.GL;
import org.lwjgl.opengl.GLCapabilities;
import org.lwjgl.system.Configuration;
import org.lwjgl.system.MemoryStack;

import java.nio.ByteBuffer;
import java.nio.IntBuffer;

import static org.lwjgl.glfw.GLFW.*;
import static org.lwjgl.opengl.GL33C.*;
import static org.lwjgl.system.MemoryUtil.NULL;

/**
 * Milestone 6 step 3d: the app's own GLFW implementation (exported from the
 * app executable) driven through LWJGL's GLFW binding the way Minecraft drives
 * it: core-profile hints, window, context, LWJGL desktop GL via MobileGlues,
 * callbacks, a render loop with input.
 *
 * Interactive for up to 30 s: the background follows the touch position and a
 * triangle tracks the cursor. Three-finger tap or Escape ends early.
 */
public final class GlfwSmokeTest {
    private static int keyEvents, charEvents, buttonEvents, cursorEvents, scrollEvents, resizeEvents;
    private static double cx = 0.5, cy = 0.5;
    private static int fbW, fbH, winW, winH;

    public static void main(String[] args) {
        System.out.println("LWJGL " + Version.getVersion() + " glfw.libname=" + System.getProperty("org.lwjgl.glfw.libname"));
        GLFWErrorCallback.createPrint(System.out).set();

        if (!glfwInit()) throw new IllegalStateException("glfwInit failed");
        System.out.println("GLFW " + glfwGetVersionString() + " platform=0x" + Integer.toHexString(glfwGetPlatform()));

        glfwDefaultWindowHints();
        glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
        glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 2);
        glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
        glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GLFW_TRUE);
        long window = glfwCreateWindow(854, 480, "Voxelium GLFW test", NULL, NULL);
        if (window == NULL) throw new IllegalStateException("glfwCreateWindow failed");

        try (MemoryStack stack = MemoryStack.stackPush()) {
            IntBuffer a = stack.mallocInt(1), b = stack.mallocInt(1);
            glfwGetWindowSize(window, a, b);
            winW = a.get(0); winH = b.get(0);
            glfwGetFramebufferSize(window, a, b);
            fbW = a.get(0); fbH = b.get(0);
        }
        System.out.println("window " + winW + "x" + winH + " framebuffer " + fbW + "x" + fbH);

        glfwSetKeyCallback(window, (w, key, sc, action, mods) -> {
            keyEvents++;
            System.out.println("key " + key + " scancode " + sc + " action " + action + " mods " + mods);
            if (key == GLFW_KEY_ESCAPE && action == GLFW_PRESS) glfwSetWindowShouldClose(w, true);
        });
        glfwSetCharCallback(window, (w, cp) -> { charEvents++; System.out.println("char U+" + Integer.toHexString(cp)); });
        glfwSetMouseButtonCallback(window, (w, button, action, mods) -> {
            buttonEvents++;
            System.out.println("mouse button " + button + " action " + action);
        });
        glfwSetCursorPosCallback(window, (w, x, y) -> {
            cursorEvents++;
            if (winW > 0 && winH > 0) { cx = x / winW; cy = y / winH; }
        });
        glfwSetScrollCallback(window, (w, dx, dy) -> scrollEvents++);
        glfwSetFramebufferSizeCallback(window, (w, width, height) -> {
            resizeEvents++;
            fbW = width; fbH = height;
            System.out.println("framebuffer resized to " + width + "x" + height);
        });

        glfwMakeContextCurrent(window);
        GLCapabilities caps = GL.createCapabilities();
        System.out.println("GL_RENDERER=" + glGetString(GL_RENDERER));
        System.out.println("GL_VERSION=" + glGetString(GL_VERSION) + " core33=" + caps.OpenGL33);
        System.out.println("current context ok=" + (glfwGetCurrentContext() == window));
        glfwSwapInterval(1);

        int program = program();
        int offsetLoc = glGetUniformLocation(program, "offset");
        int vao = glGenVertexArrays();
        glBindVertexArray(vao);
        int vbo = glGenBuffers();
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        try (MemoryStack stack = MemoryStack.stackPush()) {
            glBufferData(GL_ARRAY_BUFFER, stack.floats(-0.1f, -0.1f, 0.1f, -0.1f, 0.0f, 0.12f), GL_STATIC_DRAW);
        }
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, false, 0, 0L);

        boolean pixelOk = false;
        int frames = 0;
        double start = glfwGetTime();
        while (!glfwWindowShouldClose(window) && glfwGetTime() - start < 30.0) {
            glfwPollEvents();
            glViewport(0, 0, fbW, fbH);
            if (frames == 5) {
                // Known clear colour for a deterministic read-back.
                glClearColor(0.1f, 0.3f, 0.6f, 1.0f);
                glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
                glFinish();
                try (MemoryStack stack = MemoryStack.stackPush()) {
                    ByteBuffer px = stack.malloc(4);
                    glReadPixels(fbW / 2, fbH / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
                    int r = px.get(0) & 0xFF, g = px.get(1) & 0xFF, bl = px.get(2) & 0xFF;
                    pixelOk = Math.abs(r - 26) <= 3 && Math.abs(g - 77) <= 3 && Math.abs(bl - 153) <= 3 && glGetError() == GL_NO_ERROR;
                    System.out.println("read-back frame 5 = (" + r + "," + g + "," + bl + ") ok=" + pixelOk);
                }
            } else {
                glClearColor((float) cx * 0.5f, 0.2f, (float) cy * 0.5f + 0.2f, 1.0f);
                glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
                glUseProgram(program);
                glUniform2f(offsetLoc, (float) (cx * 2 - 1), (float) (1 - cy * 2));
                glDrawArrays(GL_TRIANGLES, 0, 3);
            }
            glfwSwapBuffers(window);
            frames++;
        }
        double secs = glfwGetTime() - start;
        System.out.printf("frames=%d in %.1fs (%.1f fps) events: key=%d char=%d button=%d cursor=%d scroll=%d resize=%d%n",
            frames, secs, frames / secs, keyEvents, charEvents, buttonEvents, cursorEvents, scrollEvents, resizeEvents);

        glfwDestroyWindow(window);
        glfwTerminate();
        boolean ok = pixelOk && frames >= 60 && caps.OpenGL33;
        System.out.println(ok ? "VOXELIUM_GLFW_OK" : "GLFW test FAILED");
    }

    private static int program() {
        int p = glCreateProgram();
        glAttachShader(p, shader(GL_VERTEX_SHADER,
            "#version 330 core\nlayout(location = 0) in vec2 pos;\nuniform vec2 offset;\n" +
            "void main() { gl_Position = vec4(pos + offset, 0.0, 1.0); }\n"));
        glAttachShader(p, shader(GL_FRAGMENT_SHADER,
            "#version 330 core\nout vec4 color;\nvoid main() { color = vec4(1.0, 0.5, 0.0, 1.0); }\n"));
        glLinkProgram(p);
        if (glGetProgrami(p, GL_LINK_STATUS) != GL_TRUE) throw new IllegalStateException("link: " + glGetProgramInfoLog(p));
        return p;
    }

    private static int shader(int type, String src) {
        int s = glCreateShader(type);
        glShaderSource(s, src);
        glCompileShader(s);
        if (glGetShaderi(s, GL_COMPILE_STATUS) != GL_TRUE) throw new IllegalStateException("compile: " + glGetShaderInfoLog(s));
        return s;
    }
}
