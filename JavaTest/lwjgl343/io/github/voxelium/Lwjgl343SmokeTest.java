package io.github.voxelium;

import org.lwjgl.*;
import org.lwjgl.openal.*;
import org.lwjgl.opengl.*;
import org.lwjgl.sdl.*;
import org.lwjgl.stb.*;
import org.lwjgl.system.*;
import org.lwjgl.system.jemalloc.*;
import org.lwjgl.util.freetype.*;
import org.lwjgl.util.shaderc.*;
import org.lwjgl.util.spvc.*;
import org.lwjgl.util.vma.*;
import org.lwjgl.vulkan.*;

import javax.imageio.*;
import java.awt.image.*;
import java.io.*;
import java.nio.*;
import java.util.concurrent.atomic.*;

import static org.lwjgl.system.MemoryStack.*;
import static org.lwjgl.system.MemoryUtil.*;
import static org.lwjgl.util.shaderc.Shaderc.*;
import static org.lwjgl.util.spvc.Spvc.*;
import static org.lwjgl.util.vma.Vma.*;
import static org.lwjgl.vulkan.KHRPortabilityEnumeration.*;
import static org.lwjgl.vulkan.VK10.*;
import static org.lwjgl.vulkan.VK12.*;

/**
 * Mac check for the LWJGL 3.4.3 jars Minecraft 26.3 uses (scripts/check-lwjgl-3.4.3.sh): calls
 * into every binding 26.3 lists, on the macOS JDK, against Mojang's own macOS natives. Run with
 * Mojang's jars it checks the harness; run with ours it checks our Java build (its JNI/libffi path,
 * since our lwjgl.jar has no Java 25 FFM classes) against a real 3.4.3 liblwjgl.
 */
public final class Lwjgl343SmokeTest {

    private static int failures;

    public static void main(String[] args) {
        check("core", () -> {
            String v = Version.getVersion();
            if (!v.startsWith("3.4.3")) throw new IllegalStateException("version " + v);
            ByteBuffer b = memAlloc(64);
            memSet(b, 7);
            if (b.get(63) != 7) throw new IllegalStateException("memSet");
            memFree(b);
            return v;
        });
        check("jemalloc", () -> {
            ByteBuffer b = JEmalloc.je_malloc(16);
            if (b == null) throw new IllegalStateException("je_malloc returned NULL");
            JEmalloc.je_free(b);
            return "je_malloc/je_free";
        });
        check("sdl", () -> {
            int v = SDLVersion.SDL_GetVersion();
            // A native-to-Java upcall through a libffi closure (what SDL event watchers need).
            AtomicReference<String> logged = new AtomicReference<>();
            SDL_LogOutputFunction cb = SDL_LogOutputFunction.create((userdata, category, priority, message) ->
                logged.set(memUTF8(message)));
            SDLLog.SDL_SetLogOutputFunction(cb, NULL);
            SDLLog.SDL_Log("voxelium upcall");
            if (!"voxelium upcall".equals(logged.get())) throw new IllegalStateException("log callback got " + logged.get());
            return "SDL " + v / 1000000 + "." + v / 1000 % 1000 + "." + v % 1000 + ", log callback OK";
        });
        check("stb", () -> {
            BufferedImage img = new BufferedImage(3, 2, BufferedImage.TYPE_INT_ARGB);
            ByteArrayOutputStream png = new ByteArrayOutputStream();
            ImageIO.write(img, "png", png);
            ByteBuffer data = memAlloc(png.size()).put(png.toByteArray()).flip();
            try (MemoryStack s = stackPush()) {
                IntBuffer w = s.mallocInt(1), h = s.mallocInt(1), c = s.mallocInt(1);
                ByteBuffer pixels = STBImage.stbi_load_from_memory(data, w, h, c, 4);
                if (pixels == null) throw new IllegalStateException(STBImage.stbi_failure_reason());
                STBImage.stbi_image_free(pixels);
                memFree(data);
                return "stbi_load_from_memory " + w.get(0) + "x" + h.get(0);
            }
        });
        check("freetype", () -> {
            try (MemoryStack s = stackPush()) {
                PointerBuffer lib = s.mallocPointer(1);
                if (FreeType.FT_Init_FreeType(lib) != 0) throw new IllegalStateException("FT_Init_FreeType");
                IntBuffer a = s.mallocInt(1), b = s.mallocInt(1), c = s.mallocInt(1);
                FreeType.FT_Library_Version(lib.get(0), a, b, c);
                FreeType.FT_Done_FreeType(lib.get(0));
                return "FreeType " + a.get(0) + "." + b.get(0) + "." + c.get(0);
            }
        });
        check("openal", () -> {
            // ALC (like GL below) loads its library in its static initialiser.
            if (ALC.getFunctionProvider() == null) throw new IllegalStateException("no function provider");
            String dev = ALC10.alcGetString(NULL, ALC10.ALC_DEFAULT_DEVICE_SPECIFIER);
            return "ALC loaded, default device " + dev;
        });
        check("opengl", () -> {
            if (GL.getFunctionProvider() == null) throw new IllegalStateException("no function provider");
            return "OpenGL library loaded";
        });
        ByteBuffer[] spirv = new ByteBuffer[1];
        check("shaderc", () -> {
            String glsl = """
                #version 450
                layout(location = 0) in vec3 pos;
                layout(location = 0) out vec4 color;
                layout(push_constant) uniform P { mat4 mvp; } p;
                void main() { gl_Position = p.mvp * vec4(pos, 1.0); color = vec4(pos, 1.0); }
                """;
            long compiler = shaderc_compiler_initialize();
            long options = shaderc_compile_options_initialize();
            shaderc_compile_options_set_target_env(options, shaderc_target_env_vulkan, shaderc_env_version_vulkan_1_2);
            long result = shaderc_compile_into_spv(compiler, glsl, shaderc_vertex_shader, "test.vert", "main", options);
            if (shaderc_result_get_compilation_status(result) != shaderc_compilation_status_success) {
                throw new IllegalStateException(shaderc_result_get_error_message(result));
            }
            ByteBuffer bytes = shaderc_result_get_bytes(result);
            spirv[0] = memAlloc(bytes.remaining()).put(bytes).flip();
            shaderc_result_release(result);
            shaderc_compile_options_release(options);
            shaderc_compiler_release(compiler);
            // glslang's own C API, exported by the same library.
            try (MemoryStack s = stackPush()) {
                GLSLangVersion v = GLSLangVersion.malloc(s);
                GLSLang.glslang_get_version(v);
                return spirv[0].remaining() + " bytes of SPIR-V; glslang " + v.major() + "." + v.minor() + "." + v.patch();
            }
        });
        check("spvc", () -> {
            if (spirv[0] == null) throw new IllegalStateException("no SPIR-V (shaderc failed)");
            StringBuilder out = new StringBuilder();
            try (MemoryStack s = stackPush()) {
                IntBuffer maj = s.mallocInt(1), min = s.mallocInt(1), pat = s.mallocInt(1);
                spvc_get_version(maj, min, pat);
                out.append("C API ").append(maj.get(0)).append('.').append(min.get(0));
                PointerBuffer pp = s.mallocPointer(1);
                spvcCheck(spvc_context_create(pp));
                long ctx = pp.get(0);
                spvcCheck(spvc_context_parse_spirv(ctx, spirv[0].asIntBuffer(), spirv[0].remaining() / 4, pp));
                long ir = pp.get(0);
                for (int backend : new int[] { SPVC_BACKEND_GLSL, SPVC_BACKEND_MSL }) {
                    spvcCheck(spvc_context_create_compiler(ctx, backend, ir, SPVC_CAPTURE_MODE_COPY, pp));
                    long compiler = pp.get(0);
                    if (backend == SPVC_BACKEND_GLSL) {
                        // As 26.3's OpenGL backend: GLSL 330 core from Vulkan SPIR-V.
                        spvcCheck(spvc_compiler_create_compiler_options(compiler, pp));
                        long opts = pp.get(0);
                        spvcCheck(spvc_compiler_options_set_uint(opts, SPVC_COMPILER_OPTION_GLSL_VERSION, 330));
                        spvcCheck(spvc_compiler_options_set_bool(opts, SPVC_COMPILER_OPTION_GLSL_ES, false));
                        spvcCheck(spvc_compiler_options_set_bool(opts, SPVC_COMPILER_OPTION_GLSL_EMIT_PUSH_CONSTANT_AS_UNIFORM_BUFFER, true));
                        spvcCheck(spvc_compiler_install_compiler_options(compiler, opts));
                    }
                    spvcCheck(spvc_compiler_compile(compiler, pp));
                    String src = memUTF8(pp.get(0));
                    if (!src.contains("main")) throw new IllegalStateException("no main in output");
                    out.append(backend == SPVC_BACKEND_GLSL ? ", GLSL 330 " : ", MSL ").append(src.length()).append(" chars");
                }
                spvc_context_destroy(ctx);
            }
            memFree(spirv[0]);
            return out.toString();
        });
        check("vulkan+vma", Lwjgl343SmokeTest::vulkanAndVma);

        System.out.println(failures == 0 ? "ALL OK" : failures + " FAILED");
        System.exit(failures == 0 ? 0 : 1);
    }

    /** A Vulkan 1.2 instance and device (MoltenVK on the Mac), then a VMA allocator and buffer. */
    private static String vulkanAndVma() {
        try (MemoryStack s = stackPush()) {
            IntBuffer count = s.mallocInt(1);
            vkCheck(vkEnumerateInstanceExtensionProperties((ByteBuffer)null, count, null));
            VkExtensionProperties.Buffer exts = VkExtensionProperties.malloc(count.get(0), s);
            vkCheck(vkEnumerateInstanceExtensionProperties((ByteBuffer)null, count, exts));
            boolean portability = exts.stream().anyMatch(e -> e.extensionNameString().equals(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME));

            PointerBuffer instExts = s.mallocPointer(1);
            if (portability) instExts.put(s.UTF8(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME));
            instExts.flip();
            VkInstanceCreateInfo ici = VkInstanceCreateInfo.calloc(s).sType$Default()
                .flags(portability ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0)
                .pApplicationInfo(VkApplicationInfo.calloc(s).sType$Default().apiVersion(VK_API_VERSION_1_2))
                .ppEnabledExtensionNames(instExts);
            PointerBuffer pp = s.mallocPointer(1);
            vkCheck(vkCreateInstance(ici, null, pp));
            VkInstance instance = new VkInstance(pp.get(0), ici);

            vkCheck(vkEnumeratePhysicalDevices(instance, count, null));
            if (count.get(0) == 0) throw new IllegalStateException("no physical device");
            PointerBuffer devs = s.mallocPointer(count.get(0));
            vkCheck(vkEnumeratePhysicalDevices(instance, count, devs));
            VkPhysicalDevice pd = new VkPhysicalDevice(devs.get(0), instance);
            VkPhysicalDeviceProperties props = VkPhysicalDeviceProperties.malloc(s);
            vkGetPhysicalDeviceProperties(pd, props);

            vkEnumerateDeviceExtensionProperties(pd, (ByteBuffer)null, count, null);
            VkExtensionProperties.Buffer dexts = VkExtensionProperties.malloc(count.get(0), s);
            vkEnumerateDeviceExtensionProperties(pd, (ByteBuffer)null, count, dexts);
            boolean subset = dexts.stream().anyMatch(e -> e.extensionNameString().equals("VK_KHR_portability_subset"));
            PointerBuffer devExts = s.mallocPointer(1);
            if (subset) devExts.put(s.UTF8("VK_KHR_portability_subset"));
            devExts.flip();

            VkDeviceQueueCreateInfo.Buffer qci = VkDeviceQueueCreateInfo.calloc(1, s).sType$Default()
                .queueFamilyIndex(0).pQueuePriorities(s.floats(1.0f));
            VkDeviceCreateInfo dci = VkDeviceCreateInfo.calloc(s).sType$Default()
                .pQueueCreateInfos(qci).ppEnabledExtensionNames(devExts);
            vkCheck(vkCreateDevice(pd, dci, null, pp));
            VkDevice device = new VkDevice(pp.get(0), pd, dci, VK_API_VERSION_1_2);

            VmaAllocatorCreateInfo aci = VmaAllocatorCreateInfo.calloc(s)
                .physicalDevice(pd).device(device).instance(instance)
                .pVulkanFunctions(VmaVulkanFunctions.calloc(s).set(instance, device))
                .vulkanApiVersion(VK_API_VERSION_1_2);
            vkCheck(vmaCreateAllocator(aci, pp));
            long allocator = pp.get(0);
            VkBufferCreateInfo bci = VkBufferCreateInfo.calloc(s).sType$Default()
                .size(65536).usage(VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            VmaAllocationCreateInfo alloc = VmaAllocationCreateInfo.calloc(s)
                .usage(VMA_MEMORY_USAGE_AUTO)
                .flags(VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT | VMA_ALLOCATION_CREATE_MAPPED_BIT);
            LongBuffer buffer = s.mallocLong(1);
            VmaAllocationInfo info = VmaAllocationInfo.malloc(s);
            vkCheck(vmaCreateBuffer(allocator, bci, alloc, buffer, pp, info));
            if (info.pMappedData() == NULL) throw new IllegalStateException("buffer not mapped");
            memSet(info.pMappedData(), 1, 65536);
            vmaDestroyBuffer(allocator, buffer.get(0), pp.get(0));
            vmaDestroyAllocator(allocator);
            vkDestroyDevice(device, null);
            vkDestroyInstance(instance, null);
            return props.deviceNameString() + ", Vulkan " + VK_API_VERSION_MAJOR(props.apiVersion()) + "."
                + VK_API_VERSION_MINOR(props.apiVersion()) + (portability ? " (portability)" : "")
                + "; VMA 64 KiB mapped buffer";
        }
    }

    private static void vkCheck(int r) { if (r != VK_SUCCESS) throw new IllegalStateException("VkResult " + r); }

    private static void spvcCheck(int r) { if (r != SPVC_SUCCESS) throw new IllegalStateException("spvc_result " + r); }

    private interface Step { String run() throws Exception; }

    private static void check(String name, Step step) {
        try {
            System.out.println("OK   " + name + ": " + step.run());
        } catch (Throwable t) {
            failures++;
            System.out.println("FAIL " + name + ": " + t);
            t.printStackTrace(System.out);
        }
    }
}
