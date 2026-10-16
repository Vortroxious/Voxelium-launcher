# Notices

This project is licensed under GPL-3.0 (see `LICENSE`).

It is an independent iOS project **inspired by** [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) (GPL-3.0, © ZalithLauncher contributors). That project builds on [PojavLauncher](https://github.com/PojavLauncherTeam/PojavLauncher) (LGPL-3.0/GPL-3.0). It is not affiliated with, or endorsed by, the ZalithLauncher team, Mojang Studios or Microsoft.

- No ZalithLauncher2 source files are included. Behaviour that mirrors upstream is cited in code comments.
- ZalithLauncher2's README adds GPLv3 §7 terms: keep copyright notices, and distinguish modified versions by name or version. This project uses its own name and version (0.x). The name still contains "Zalith". Before any public release, confirm with the maintainers or rename (open item).
- "Minecraft" is a trademark of Mojang Synergies AB. This launcher does not include or redistribute any Minecraft game files. They are downloaded from Mojang's servers to the user's device.

## Bundled third-party components (in the IPA)
- **OpenJDK 17.0.20 runtime for iOS arm64**, built by AngelAuraMC (https://assets.angelauramc.dev/openjdk/ios-arm64/jre17-ios-aarch64.zip). License: GPL-2.0 with the Classpath Exception. Per-module notices ship in `java/jre17/legal/` inside the app.
- **UniversalJIT26.js, UniversalJIT26Extension.js** from Amethyst-iOS (GPL-3.0), unmodified apart from a header comment.
- **jni.h, jni_md.h** from OpenJDK 17u (GPL-2.0 with the Classpath Exception).
- `App/ZalithIOS/Native/JITSupport.m` adapts JIT detection and breakpoint helpers from Amethyst-iOS `Natives/utils.m` (GPL-3.0).
- **ANGLE** (libEGL.framework, libGLESv2.framework), built from https://chromium.googlesource.com/angle/angle at `33f8caff4b77`. License: BSD-3-Clause (ANGLE `LICENSE`). Third-party code compiled into those libraries has its own notices under ANGLE's `third_party/`; a full notices file must be gathered before any public release (open item).
- **Khronos EGL/GLES headers** (`App/ZalithIOS/Native/khronos/`), copied from ANGLE's `include/`. EGL headers are Apache-2.0, GLES headers MIT, and `eglext_angle.h`/`gl2ext_angle.h` BSD (ANGLE).
- **LWJGL 3.3.3** (jars in `java/lwjgl/`, natives `liblwjgl*.dylib`), built from AngelAuraMC/lwjgl3 `6a564a8b4b14`. License: BSD-3-Clause (LWJGL `LICENSE.md`). Bundled third-party code: **libffi 3.4.8** (MIT, statically linked into `liblwjgl`), **stb** (public domain/MIT) and **tinyfiledialogs** (zlib), with license texts in the LWJGL source tree. All must be included in a notices file before any public release.
- **MobileGlues** (`Frameworks/libmobileglues.dylib`), built from https://github.com/MobileGL-Dev/MobileGlues at `f0fb4d32794a`. License: **LGPL-2.1**. It is dynamically linked; its source and our build script (`scripts/build-mobileglues.sh`) let users rebuild and replace it. Compiled in: **glslang 15.0.0** (several permissive licences, see its LICENSE.txt), **SPIRV-Tools** (Apache-2.0), **SPIRV-Headers** (MIT-style), **glm** (MIT/Happy Bunny), **xxhash** by Stephan Brumme (MIT), and **FastSTL** (MobileGL-Dev, **no licence declared**; must be resolved before any public release).
- **SPIRV-Cross** `vulkan-sdk-1.4.304.0` (`Frameworks/libspirv-cross-c-shared.0.dylib`), Apache-2.0.
- **GLFW 3.4 public header** (`App/ZalithIOS/Native/glfw/GLFW/glfw3.h`), from https://github.com/glfw/glfw tag 3.4. License: zlib/libpng. Used only to compile the app's own GLFW API implementation (`ZLGLFW.m`). No GLFW source code is included.
