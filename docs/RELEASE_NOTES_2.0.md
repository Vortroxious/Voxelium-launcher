# Voxelium 2.0

Voxelium 2.0 adds a **Vulkan renderer** and runs **Minecraft 26.3**.

> Not affiliated with Mojang, Microsoft, Modrinth, the Forge or NeoForge projects. You need a Minecraft: Java Edition account. JIT is required: start Voxelium from **StikDebug**. See the [install guide](INSTALL.md).

## New
- **Minecraft 26.3.** 26.3 replaced its window system with SDL3 and renders with Vulkan. Voxelium now bundles SDL3 for iOS and a Vulkan driver, so 26.3 runs, with Fabric too. **It needs iOS 26 or later**, because the Vulkan driver uses Metal 4.
- **Choose the renderer when you play.** On an installed version, **Play** offers:

  | Version | Choices |
  |---|---|
  | 1.17 – 26.1.2 | **Play with MobileGlues** (OpenGL ES on ANGLE, as in 1.0) or **Play with Vulkan** (OpenGL 4.6 through Mesa's Zink on the KosmicKrisp Vulkan driver) |
  | 26.3 | **Play with Vulkan** only |
  | 1.13 – 1.16.5 | **Launch**, as before (gl4es) |

  - Voxelium remembers your choice for each version.
  - Each renderer can start once per app launch. To switch, close Voxelium and start it again from StikDebug.
  - On iOS below 26, **Play with Vulkan** is greyed out with the reason, and everything else works as in 1.0.
- **A bigger hotbar.** The new **Large interface** switch (Account tab, on by default) sets the game resolution so Minecraft can show its largest hotbar and menus, and sets Minecraft's GUI Scale to Auto. On an iPhone 15 Pro Max the default resolution becomes 56% instead of 50%. Tapping hotbar slots is also easier.
- **Touch controls for 26.3,** the same as for older versions (joystick, buttons, hotbar). With 26.3, hardware keyboards and game controllers go through SDL.

## Tested
On an iPhone 15 Pro Max with iOS 27.0, with this IPA (build 202610240359):

| Version | Renderer | Result |
|---|---|---|
| Fabric 1.21.11 | MobileGlues | Joined a world, quit cleanly; peak memory 2.3 GB |
| Fabric 1.21.11 | Vulkan (Zink) | OpenGL 4.6 on the A17 Pro GPU; joined a world, quit cleanly; peak 2.85 GB |
| Fabric 26.3 with Sodium + Iris | Vulkan | Native Vulkan on KosmicKrisp; joined a world, quit cleanly; peak 2.0 GB |

- **Earlier test builds:** vanilla 26.3 on Vulkan joined a world, and the bigger hotbar was checked in Fabric 1.21.11 (GUI scale 3 at 56%).
- **NeoForge and Forge** are unchanged from 1.0. Their Vulkan option is new and only lightly tested: one NeoForge start on Vulkan stopped before Java began, and worked after a relaunch.

## Updating
Install over 1.0 with Sideloadly using the **same Apple ID**, so your versions, mods and worlds stay. The app is larger than 1.0, because it now carries the Vulkan driver, SDL3 and LWJGL 3.4.3.

## Known limits
- **Not supported yet:**
  - Minecraft 26.2: its OpenGL renderer shows a black screen, and it has no Vulkan renderer;
  - 1.12.2 and older;
  - Forge before 1.17;
  - 26.3's OpenGL backend on iPhone, so Voxelium always starts 26.3 on Vulkan.
- **Vulkan has limits:**
  - **iOS 26+ only.**
  - Shader packs that need geometry shaders don't work on it, because the driver has none yet.
  - Photon needs more shared memory than Apple's GPUs allow.
  - It can use noticeably more memory than MobileGlues (up to about 2.85 GB in Fabric 1.21.11, against roughly 3.4 GB allowed). If the game closes on Vulkan, use MobileGlues or lower the render distance.
- **Memory:** iOS limits the app's memory (about 3.4 GB on the test phone). Keep the render distance at 8–10 with shaders.
- **One phone:** tested on a single iPhone; iPad is not tested.
- **Free Apple ID:** apps signed with one must be refreshed every 7 days.

## Files
- `Voxelium-2.0-unsigned.ipa`: install it with Sideloadly ([step by step](../README.md#installing-on-your-iphone)). SHA-256: `e1d6f28dc6a4391893b60203c7d1f08275d584609dfaf03a26f6222b8b85bfe4` (build 202610240359, 213,461,120 bytes)
- `THIRD_PARTY_NOTICES.txt`: licences of the bundled components. New in 2.0: SDL 3.4.14 (zlib); Mesa with KosmicKrisp, Zink and EGL (MIT); LWJGL 3.4.3, Vulkan Memory Allocator, shaderc, glslang, SPIRV-Tools and SPIRV-Cross.
- Source code: this tag, including `patches/` and the build scripts for every bundled library (`scripts/build-zink.sh`, `build-sdl3.sh`, `build-lwjgl.sh`, `build-shaderc.sh`).

## Thanks
ZalithLauncher2, Amethyst-iOS and PojavLauncher (prior art), AngelAuraMC (iOS OpenJDK and LWJGL builds), the Mesa project and LunarG (Zink and KosmicKrisp), the SDL, LWJGL, MobileGlues, ANGLE, gl4es, OpenAL Soft, FreeType, shaderc and SPIRV-Cross projects, the Forge and NeoForge projects, and Modrinth.
