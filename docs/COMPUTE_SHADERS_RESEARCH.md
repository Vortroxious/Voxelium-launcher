# Compute shaders on iPhone: Zink feasibility spike

Status: **spike complete, 2026-10-22.** The prototype is on branch `spike/zink-compute`: the build, Mesa patches, probe and this report. The in-app test and the experimental IPA script are on branch `claude/cool-lumiere-997bc1`. Neither is merged or pushed.

**Short answer: yes, with caveats.** On the iPhone 15 Pro Max, Mesa's Zink running on Mesa's KosmicKrisp (ported to iOS here) gives a **GL 4.6 core context in which a compute shader writes an SSBO and reads back correctly**. Two conditions apply:
- the GL version has to be forced (`MESA_GL_VERSION_OVERRIDE=4.6`), because KosmicKrisp has no geometry shaders or transform feedback yet;
- memory grew sharply during the frame test, and it is not yet known whether it levels off.

MoltenVK was not needed and was not tried.

## Question

Can Voxelium give Minecraft an OpenGL with compute shaders on iPhone? That means GL 4.3, or GL 4.2 plus `GL_ARB_compute_shader`. Iris needs it to run packs such as Photon, Noble, Mellow and Visual Vibrance.

Today the game renders through MobileGlues on ANGLE's Metal backend. That path stops at OpenGL ES 3.0:
- `kMaxSupportedGLVersion = gl::Version(3, 0)` in ANGLE's `mtl_common.h`;
- `ContextMtl::dispatchCompute` is `UNIMPLEMENTED()` at ANGLE 33f8caf.

So Iris reports "This PC does not support compute shaders" (`docs/ENGINEERING_LOG.md`, Photon run).

## Approach and priority

Mesa's **Zink** implements desktop OpenGL (up to 4.6) on top of Vulkan. iOS has no Vulkan of its own, so Zink needs a Vulkan-on-Metal driver. In order of preference:

1. **KosmicKrisp** (LunarG, in Mesa, MIT): a conformant Vulkan 1.4 on Metal 4. Upstream supports macOS only, so this spike ports it to iOS (`patches/mesa/`).
2. **MoltenVK** (Khronos, Apache-2.0): the last resort, tried only if KosmicKrisp hits a recorded blocker.

Everything is opt-in:
- `scripts/build-zink.sh` builds into `build/deps/zink-out/<vk>/`;
- only the isolated experimental IPA (`scripts/build-ipa-zink-experimental.sh`, its own bundle ID) bundles it.

The 1.0 IPA and the shipping graphics path do not change.

## Measured on the device

iPhone 15 Pro Max (A17 Pro), iOS 27.0. The experimental IPA, build `202610221127`, was installed alongside Voxelium 1.0 as `io.github.voxelium.launcher.zinkexp.BANQ4R4Z6N`; `xcrun devicectl device info apps` confirmed the build. The logs were copied with `devicectl device copy from` on 2026-10-22 at 11:34Z, and are in `docs/evidence/2026-10-22-zink-kosmickrisp-iphone15promax-ios27.log`. The Mesa log file was not created, so Mesa printed nothing.

**JIT was not attached** for either run: launcher.log says `JIT/debugger attached: false`. So the whole GL stack (Zink, KosmicKrisp and Metal shader compilation) runs without JIT. Only the game's JVM needs it.

**Vulkan (gate A2):**
- `vkCreateInstance` OK in 0.6 ms. One physical device: **`Apple A17 Pro GPU`, apiVersion 1.4.363, driverID 28, `KosmicKrisp (Mesa 27.0.0-devel (git-9b3209540c))`**, 137 device extensions.
- Features: `geometryShader=0 tessellationShader=1 transformFeedback=0`, with `robustBufferAccess2`, `robustImageAccess2` and `nullDescriptor` all 1.

**GL 4.6 override run (gate A3):** `MESA_GL_VERSION_OVERRIDE=4.6 MESA_GLSL_VERSION_OVERRIDE=460`.
- The first 4.3 core context request succeeded. EGL + context took 1415 ms on this first launch, with a cold Metal and Mesa cache.
- `GL_RENDERER=zink Vulkan 1.4(Apple A17 Pro GPU (MESA_KOSMICKRISP))`
- **`GL_VERSION=4.6 (Core Profile) Mesa 27.0.0-devel`, `GL_SHADING_LANGUAGE_VERSION=4.60`**, 217 extensions.
- Present: `GL_ARB_compute_shader`, `GL_ARB_shader_storage_buffer_object`, `GL_ARB_shader_image_load_store`, `GL_ARB_tessellation_shader`, `GL_ARB_multi_draw_indirect`, `GL_ARB_gpu_shader5`. Absent: `GL_ARB_geometry_shader4`, `GL_ARB_transform_feedback3`.
- `GL_MAX_COMPUTE_WORK_GROUP_COUNT=(2147483646, 65535, 65535)`, `GL_MAX_COMPUTE_WORK_GROUP_SIZE=(1024, 1024, 1024)`, 1024 invocations.
- Compute compile+link 10.4 ms. `dispatch(16,1,1)` + barrier + finish 26.56 ms. Read-back 0.02 ms. glError 0. **`VOXELIUM_ZINK_COMPUTE_OK`**.
- Full-screen quad at 1290×2796: the first frame took 51.8 ms, then 299 frames took 160.2 ms (**0.54 ms/frame**). The centre pixel read back as expected. This is a light shader, so it measures overhead, not Minecraft-level work.

**Native run (no override; separate launch, separate shader cache):**
- Core 4.3, 4.2, 4.1, 4.0, 3.3 and 3.2 were all refused with `EGL_BAD_MATCH` (0x3009). The default context is **`2.1 Mesa 27.0.0-devel`, GLSL 1.20**, with 287 extensions, including the same compute/SSBO/image-load-store extensions.
- Compute was skipped by design, because GLSL 1.20 cannot compile `#version 430`.
- Context in 10.9 ms (warm). Quad: 0.38 ms/frame. Result: `VOXELIUM_ZINK_NATIVE_GL2.1_DRAW_OK`.

**Memory (`phys_footprint`, the number jetsam uses):**

| Point | GL 4.6 override run | Native run |
|---|---|---|
| Before init (app already running) | 38.5 MB | 39.2 MB |
| After the context | 48.4 MB | 48.9 MB |
| After the compute dispatch | 83.8 MB | — |
| After 300 frames at 1290×2796 | **611.3 MB** | **868.1 MB** |

That frame-test growth, +527 MB and +819 MB, is the open problem. One 1290×2796 RGBA8 target is 14 MB. On the Mac the same kind of loop levelled off at about 154 MB between frame 300 and frame 3000 (`PROBE_FRAMES=3000`), so it is not a leak there. On the phone, 300 frames are not enough to tell a pool that fills once from a per-frame leak. With a 3.4 GB limit, a per-frame leak would end a Minecraft session within seconds, so a longer device run, logging the footprint every 300 frames, is the first follow-up.

## Built (2026-10-22)

`scripts/build-zink.sh` (KosmicKrisp is the default `ZINK_VK`) builds Mesa 9b32095 plus `patches/mesa/0001-0006` for iOS arm64, with a minimum of iOS 26.0, because KosmicKrisp needs Metal 4. The output goes to `build/deps/zink-out/kosmickrisp/`:

| File | Size (stripped) |
|---|---|
| `libEGL_mesa.dylib` | 0.85 MB |
| `libgallium-27.0.0-devel.dylib` (Zink, GL frontend, NIR, SPIR-V) | 17.8 MB |
| `libvulkan_kosmickrisp.dylib` | 13.3 MB |

All three are Mach-O platform 2 (iOS), arm64. They depend only on `@rpath` libraries and system libraries (libSystem, libc++, libobjc, libz, Foundation, CoreFoundation, Metal).

What the port needed. Each fix is one small patch:

| Patch | Why |
|---|---|
| 0001 zink: Vulkan library from `ZINK_VULKAN_LIBRARY`, bare-ICD entry | iOS has no Vulkan loader. A bare Mesa ICD exports only `vk_icdGetInstanceProcAddr` and has no `vkEnumerateInstanceLayerProperties`; without the stub, Zink's instance creation returned NULL with no message. |
| 0002 kosmickrisp: `MTLCreateSystemDefaultDevice` on iOS | `MTLCopyAllDevices()` is macOS-only. |
| 0003 kosmickrisp: `vm_remap`/`vm_map`/`vm_deallocate` on iOS | The iOS SDK rejects `mach_vm.h` ("mach_vm.h unsupported"). The `vm_*` calls are the same on 64-bit. |
| 0004 zink: link `-lobjc` on darwin | Zink compiles as Objective-C on darwin. With no window-system platform, the iOS link failed on `___objc_personality_v0`. |
| 0005 kosmickrisp: link Foundation/Metal/QuartzCore | The driver links with `-undefined dynamic_lookup`, which left 19 Metal symbols to flat lookup. That only works if the host already loaded Metal. |
| 0006 egl: surfaceless reaches Zink without DRM | On Apple platforms, the surfaceless platform only reached Zink with `LIBGL_ALWAYS_SOFTWARE=1`, and that same variable makes Zink demand a CPU Vulkan device. |

Runtime settings: `MESA_LOADER_DRIVER_OVERRIDE=zink` and `ZINK_VULKAN_LIBRARY=<path to the driver dylib>`. Leave `LIBGL_ALWAYS_SOFTWARE` unset.

## Measured on the build Mac (Apple M4, macOS 27.0; not the device)

`scripts/build-zink.sh mac` builds the same Mesa, with the same patches, for the Mac and runs `scripts/zink-probe.c`. That checks the whole stack before it goes to a phone. Logs: `docs/evidence/2026-10-22-zink-kosmickrisp-mac-probe-*.log`.

- **Renderer:** `zink Vulkan 1.4(Apple M4 (MESA_KOSMICKRISP))`. Zink warns that the device "doesn't support base Zink requirements: have_EXT_custom_border_color".
- **Without overrides:**
  - Every core-profile request from 4.6 to 3.2 fails with `EGL_BAD_MATCH`. The default context is **`2.1 Mesa 27.0.0-devel`, GLSL 1.20**. GLSL ES goes up to 3.10.
  - The 2.1 context still lists `GL_ARB_compute_shader`, `GL_ARB_shader_storage_buffer_object`, `GL_ARB_shader_image_load_store`, `GL_ARB_tessellation_shader`, `GL_ARB_multi_draw_indirect` and `GL_ARB_gpu_shader5`.
  - Missing: geometry shaders (`GL_ARB_geometry_shader4` no) and transform feedback (`GL_ARB_transform_feedback3` no). Mesa needs transform feedback for GL 3.0 and geometry shaders for 3.2, which is why the version stops at 2.1. KosmicKrisp does not implement either yet; LunarG's roadmap lists tessellation/geometry as upcoming work.
- **With `MESA_GL_VERSION_OVERRIDE=4.6 MESA_GLSL_VERSION_OVERRIDE=460`:**
  - **`4.6 (Core Profile) Mesa 27.0.0-devel`, GLSL 4.60, 217 extensions.**
  - Max work group count is 2147483646×65535×65535; max size 1024×1024×1024.
  - A `#version 430` compute shader writes `i*3+1` into a 1024-uint SSBO, and the read-back matches exactly: **`VOXELIUM_ZINK_COMPUTE_OK`**, GL error 0.
  - Compute compile+link: 4.2–6.2 ms.
  - Dispatch + `glFinish`: 88 ms on the first run (Metal pipeline creation), 10 ms when Mesa's shader cache was warm.
- **Frame time:** 300 frames of a full-screen pass (16 sin/cos per pixel) at 1290×2796, each one finished. The first frame took 124.7 ms with a cold shader cache and 19.1 ms with a warm one. Later frames averaged **1.2–2.1 ms** over two runs. The centre pixel read 128,128,117,255, as expected.
- **Mesa shader-cache bug (found here):**
  - After a run with the 4.6 override, a native (2.1) run found the same `#version 430` compute shader in Mesa's disk cache.
  - `GL_COMPILE_STATUS` then read 1, and `glLinkProgram` crashed (`EXC_BAD_ACCESS` in `cross_validate_globals`, on Mesa's GL thread).
  - With `MESA_SHADER_CACHE_DISABLE=true`, the compile fails correctly ("GLSL 4.30 is not supported").
  - The device test therefore keeps a separate cache directory per mode, and the probe does not try compute below GL 4.3.
- **Memory (`phys_footprint`, the number iOS's jetsam limit uses):**

  | Point | Footprint |
  |---|---|
  | Before EGL | 2.0 MB |
  | After the context | 14.2 MB |
  | After the compute test | 59.8 MB |
  | After the frames (1290×2796 RGBA8 target plus pipelines) | 163.0 MB |

These are Mac numbers. An M4 is much faster than an A17 Pro, and macOS is not iOS. They show that the stack works and how much it costs, nothing more.

## Read only, not measured (2026-10-22)

- **Mesa `main` 9b32095 (27.0.0-devel):**
  - `meson.build` turns on DRI, and so EGL, on darwin when Zink is built, and forces Vulkan beta extensions on darwin.
  - With `-Dplatforms=` (empty), EGL builds its surfaceless platform (`src/egl/drivers/dri2/platform_surfaceless.c`).
- **Zink on Apple dlopens `@rpath/libvulkan.1.dylib`** (`VK_LIBNAME`, `zink_screen.c`). iOS has no Vulkan loader. Patch 0001 makes Zink load the library named in `ZINK_VULKAN_LIBRARY`, and accept a bare Mesa ICD, which exports only `vk_icdGetInstanceProcAddr`.
- **KosmicKrisp:**
  - Mesa's docs: "No iOS support is present as of now". iOS was considered in the design, targeting A14 and newer, and the driver needs macOS 26 / Metal 4.
  - Phoronix (2026-10-03, XDC2026): iOS needs more resources before it can happen.
  - In the source, the macOS-only API in the Metal bridge is `MTLCopyAllDevices()`, which is not in the iOS SDK. Patch 0002 uses `MTLCreateSystemDefaultDevice()` on iOS.
  - The driver links with `-Wl,-undefined,dynamic_lookup`. The iOS linker accepts it with "deprecated on iOS" (checked with a test dylib).
- **Build-time tools:**
  - Mesa compiles KosmicKrisp's OpenCL C helpers with LLVM/Clang, libclc and SPIRV-LLVM-Translator, through `mesa_clc`, `vtn_bindgen2` and `kk_clc`. A cross build cannot run its own copies, so a host build supplies them.
  - These tools come from conda-forge through micromamba: LLVM/Clang 22.1.8, libclc 22.1.8, libllvmspirv 22.1.x and SPIRV-Tools 2026.4.
  - Nothing from LLVM is bundled, and the iOS build uses `-Dllvm=disabled`.
- **No JIT, why:** Zink has no runtime code generation of its own (no llvmpipe). GLSL becomes NIR, then SPIR-V. KosmicKrisp turns SPIR-V into NIR, then MSL, and Metal compiles the MSL in Apple's own process. The device run confirmed it: both modes passed with no JIT attached.
- **Prior art:** Amethyst-iOS offers a Zink renderer on MoltenVK (`docs/ENGINEERING_LOG.md`, renderer survey).

## Licences

| Component | Licence | Bundled? |
|---|---|---|
| Mesa (Zink, gallium, EGL, KosmicKrisp) | MIT; some files carry other permissive SPDX tags, listed in `zink-out/<vk>/LICENSES/` | Experimental IPA only |
| MoltenVK | Apache-2.0 | Not used (KosmicKrisp hit no blocker) |
| LLVM/Clang, libclc, SPIRV-LLVM-Translator, SPIRV-Tools | Apache-2.0 with LLVM exception / NCSA / Apache-2.0 | No (build-time only) |

All of these are compatible with Voxelium's GPL-3.0.

## Verdict

**Feasible. KosmicKrisp is the route, and MoltenVK is not needed.** On the iPhone, Zink + KosmicKrisp provides GL 4.6 core with working compute, SSBOs and image load/store, which is what Iris checks for compute packs. It runs without JIT and adds about 6.4 MB to the IPA (191.3 MB vs 184.8 MB).

It is not ready to ship. In order of risk:

1. **Memory growth during frames** (+0.5–0.8 GB in 300 frames on the phone, flat on the Mac). Voxelium already peaks at 2.4–2.6 GB with BSL on MobileGlues (1.0 device pass), against a limit of about 3.4 GB. This needs a long device run, then a fix in KosmicKrisp or Zink if it is per-frame. It could rule the route out.
2. **No geometry shaders or transform feedback in KosmicKrisp.** Native GL is 2.1, so Minecraft 1.17+ (GL 3.2 core) only gets a context with the 4.6 override. Vanilla rendering and compute-based packs do not use either feature. Packs with geometry programs (`.gsh`, see the 15-pack scan in `docs/ENGINEERING_LOG.md`) will fail to link those programs. LunarG lists tessellation/geometry as upcoming KosmicKrisp work.
3. **Not tested with the game.** The probe is a compute dispatch and a quad. Minecraft and Iris exercise far more GL than that, and Zink warned "doesn't support base Zink requirements: have_EXT_custom_border_color" (on the Mac).
4. **iOS 26 or later**, because KosmicKrisp is Metal 4 only. The app supports iOS 16, so the Zink renderer would be offered only on iOS 26 and later with an A14 or newer chip.

**Estimate to wire Zink into `MinecraftLauncher.swift` as an optional shader-pack renderer** (Minecraft 1.17+, iOS 26+), once the memory question is answered:

| Work | Estimate |
|---|---|
| Presentation: today `VXGLFW.m` creates an ANGLE EGL window surface on the `CAMetalLayer`, and Mesa here is surfaceless. Either port Mesa's Metal WSI (`VK_EXT_metal_surface` + kopper) to iOS so EGL gets a window surface, or render into an FBO and present it through Metal (IOSurface / `VK_EXT_metal_objects`). | 1–2 weeks |
| GL library for LWJGL: `VOXELIUM_GL_LIBRARY` points LWJGL at a library that exports `gl*`. Mesa ships no libGL here, so a small shim (or `eglGetProcAddress` through GLFW) is needed. | 2–4 days |
| Launcher: renderer choice ("MobileGlues" / "Zink (experimental)"), environment (`MESA_LOADER_DRIVER_OVERRIDE`, `ZINK_VULKAN_LIBRARY`, `MESA_GL_VERSION_OVERRIDE=4.6`, a per-version `MESA_SHADER_CACHE_DIR`), bundling, licence notices | 2–3 days |
| Getting Minecraft + Iris + one compute pack (Photon) to render, and fixing what breaks in Zink/KosmicKrisp | 1–3 weeks, the least predictable |

Total: about **3–6 weeks**, with presentation and the unknown Minecraft/Iris issues as the wide part of the range.
