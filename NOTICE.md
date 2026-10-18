# Notices

This project is licensed under GPL-3.0 (see `LICENSE`).

It is an independent iOS project **inspired by** [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) (GPL-3.0, © ZalithLauncher contributors). That project builds on [PojavLauncher](https://github.com/PojavLauncherTeam/PojavLauncher) (LGPL-3.0/GPL-3.0). It is not affiliated with, or endorsed by, the ZalithLauncher team, Mojang Studios or Microsoft.

- No ZalithLauncher2 source files are included. Behaviour that mirrors upstream is cited in code comments.
- ZalithLauncher2's README adds GPLv3 §7 terms: keep copyright notices, and distinguish modified versions by name or version. This project has its own name (**Voxelium**, renamed from the working title on 2026-10-17) and version (0.x), and includes no ZalithLauncher2 code.
- "Minecraft" is a trademark of Mojang Synergies AB. This launcher does not include or redistribute any Minecraft game files. They are downloaded from Mojang's servers to the user's device.

## Bundled third-party components (in the IPA)
The complete licence texts are in **[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)**, generated from the exact sources built by `scripts/collect-licenses.sh` and shipped inside the app (Diagnostics → About Voxelium & licences). Summary:

| Component | Version / source | Licence | How it ships |
|---|---|---|---|
| OpenJDK runtimes 8, 17, 21, 25 | AngelAuraMC iOS builds (`scripts/fetch-runtime.sh`: 1.8.0_472, 17.0.20, 21.0.8, 25.0.4) | GPL-2.0 with Classpath Exception | `java/jre*/`, with each runtime's `legal/` notices |
| ANGLE | chromium.googlesource.com/angle/angle `33f8caff4b77` | BSD-3-Clause; includes abseil (Apache-2.0), Perfetto (Apache-2.0), zlib, LLVM libc++ (Apache-2.0 WITH LLVM-exception), xxHash (BSD-2) | `libEGL.framework`, `libGLESv2.framework` |
| MobileGlues | MobileGL-Dev/MobileGlues `f0fb4d32794a` + `patches/mobileglues/0001–0014` | **LGPL-2.1**, dynamically linked and rebuildable (`scripts/build-mobileglues.sh`); includes glslang 15.0.0, SPIRV-Tools, SPIRV-Headers, GLM, xxhash (Brumme). FastSTL (no licence) was removed by patch 0002 | `libmobileglues.dylib` |
| SPIRV-Cross | `vulkan-sdk-1.4.304.0` | Apache-2.0 | `libspirv-cross-c-shared.0.dylib` |
| gl4es | PojavLauncherTeam/gl4es `c3d6a54f8a2c` + `patches/gl4es` | MIT | `libgl4es.dylib` |
| LWJGL 3.3.3 and 3.4.1 | AngelAuraMC/lwjgl3 `6a564a8b4b14`, `702c2102a287` (3.4.1 patch in `patches/lwjgl`) | BSD-3-Clause; libffi 3.4.8/3.5.2 (MIT), stb (MIT/public domain), tinyfiledialogs (zlib) | `java/lwjgl*/` |
| FreeType | 2.13.3 | FTL (chosen from FTL/GPL-2.0) | `libfreetype.dylib` |
| OpenAL Soft | 1.25.2 | **LGPL-2.0+**, dynamically linked, rebuildable (`scripts/build-openal.sh`) | `libopenal.dylib` |
| UniversalJIT26.js, UniversalJIT26Extension.js; JIT helpers in `JITSupport.m` | Amethyst-iOS | GPL-3.0 | app bundle / compiled in |
| Khronos EGL/GLES headers, GLFW 3.4 header, `jni.h` | build-time headers only | Apache-2.0 / MIT / zlib / GPL-2.0+CE | not shipped as code |
