# Engineering Log

## 2026-10-15
- **Environment:** macOS 27.0 on an M4. At first only Command Line Tools were present: no Xcode, no iOS SDK, 14 GiB free disk, no signing identities. See ENVIRONMENT_REPORT.
- **Upstream:** tag 2.6.1 = `ed872eb`, versionName 2.6.1 / code 200043. Shallow-cloned into a scratch dir for the audit. No code was copied.
- **Finding:** upstream `Rule.checkRules` is not vanilla semantics (it rejects only osx-allow rules), and `filterLibrary` drops all `org.lwjgl`. I chose to implement the vanilla algorithm evaluated as `linux/aarch64` plus the same LWJGL filter.
- **Prior art:** PojavLauncher_iOS (archived) → Amethyst-iOS (active, GPL-3.0). iOS JRE zips are reachable at assets.angelauramc.dev (HTTP 200).
- **Fixtures:** `version_manifest_v2.json`, `1.20.1.json`, `1.12.2.json` and `assetindex-5.json` were downloaded from piston-meta. Their SHA-1s match the hashes published in the manifest. The manifest has 919 versions; latest release is 26.3.
- **Initial game target:** 1.20.1 (Java 17, asset index 5).
- **Expected values:** test expectations (38 classpath libraries for 1.20.1, 29 for 1.12.2, 3575 unique asset objects, 651,432,558 bytes) were computed with an independent Python script before the Swift tests were written.
- **Offline UUID vectors:** computed with `java.util.UUID.nameUUIDFromBytes` on JDK 26 (Notch → b50ad385-829d-3141-a216-7e7d7539ba7f).
- **First `swift test`:** 1 failure, `knownSHA1`. The expected constant I had typed was wrong. `shasum` gives `0205c49d…`, and the test was corrected to that value.
- **Re-running `swift test`** (incremental, then clean) failed with `plugin for module 'TestingMacros' not found`. The same failure then appeared in the earlier working probe package, so it is a toolchain-state issue, not project code. Shortly after, the user installed Xcode 27.0 (27A266a) and `xcode-select` switched to it. All tool invocations now fail with "You have not agreed to the Xcode license agreements". Blocked on `sudo xcodebuild -license accept`, which only the user can run.
- **Xcode project:** `App/ZalithIOS.xcodeproj` was hand-written (objectVersion 77, synchronized folder group, local package reference to `..`). `plutil -lint` passes. It has **not** been opened or built by Xcode yet.
- **Xcode license:** the user accepted it, and `xcodebuild -checkFirstLaunchStatus` now returns 0.
- **Tests:** `swift test` on a clean build passed: 54 tests in 10 suites. The earlier TestingMacros failure did not recur once Xcode was the active toolchain.
- **Simulator build (Debug):** BUILD SUCCEEDED on the first try with the hand-written project. Fixed two warnings: `@MainActor` on `DeviceInfo.systemDescription`, and the iPad orientation keys.
- **Simulator runtime:** none installed (`simctl list runtimes` is empty). It was not downloaded because of disk space (11 GiB free). So there was no runtime UI test.
- **Unsigned IPA:** built with `scripts/build-ipa.sh`: arm64, platform iOS, 341,581 bytes, SHA-256 `5eb43dc8…cc70`. `codesign` reports it unsigned.
- **Live check:** `zalith-cli plan 1.20.1` downloaded the manifest and version JSON (SHA-1 verified). The plan reports 41 game files (78.3 MB), 651.7 MB of assets, 49 LWJGL-family entries replaced, and 39 classpath entries.
- **Commit `b8c0f21`:** the IPA was rebuilt from it (SHA-256 `f5b27b4e…8231`, unsigned).
- **First device install (user ran Sideloadly with a free Apple ID):** iPhone 15 Pro Max (iPhone16,2), iOS 27.0 (24A437), Developer Mode enabled, wired.
  - Installed as `io.github.zalithios.launcher.BANQ4R4Z6N`, version 0.1.0, display name "Zalith iOS". After the install, "Get More Ram" no longer appeared in `devicectl device info apps`; a free Apple ID can only keep 3 sideloaded apps at a time, which would explain it.
  - `devicectl device process launch` succeeded; the process was running (PID 58997).
  - `launcher.log`, copied off the device, shows two clean startups with no errors and `JIT/debugger attached: false`, as expected without StikDebug.
  - The app downloaded `config/version_manifest_v2.json` on the device; copied back, it parses to 919 versions, latest release 26.3.
  - Not yet checked: on-device install of a game version, UI interactions, and behaviour with StikDebug attached.
- **First on-device game install (user tapped Install at about 20:11 local time):** the files on the device belong to **1.21.11**, not 1.20.1 (adjacent rows in the list). The user most likely tapped the wrong row.
  - In place: all 47 game files (client jar 29.7 MB, asset index 29, `client-1.21.2.xml`, 44 library jars), matching `zalith-cli plan 1.21.11`.
  - Assets: **1013 of 4591** objects (expected count taken from Mojang's index 29), all written at 20:12, and no progress after that.
  - **Cause: my `devicectl device process launch --terminate-existing` at 20:12:57 killed the app mid-install.** This is not a downloader failure. Lesson: never launch with `--terminate-existing` while the user may be using the app.
  - `launcher.log` had no errors, because successful downloads aren't logged.
- **Bug found from that partial install:** the app marked a version "Installed" as soon as its JSON existed, so the half-finished 1.21.11 showed as installed.
  - Fix: `GameInstaller` writes `versions/<id>/.zalith-install-complete` only when every file is verified, and removes it at the start of each run. The app now checks that marker.
  - New `InstallerTests` cover an interrupted install followed by a resume, and a failed repair clearing the marker. 56/56 tests pass.
  - The IPA was rebuilt (SHA-256 `1b53f66b…2944`); it is not yet installed on the device.
- **Open risk (not yet tested):** the downloads use a plain `URLSession`, so iOS will likely suspend them if the app goes to the background. A full asset install currently needs the app kept in the foreground. A background `URLSession` is the proper fix.
- **1.20.1 install on device (20:17–~20:20 local, old build, the fixed IPA was not sideloaded):** files copied off the device and compared with Mojang's index 5 and the 1.20.1 JSON:
  - assets: all **3575/3575** present;
  - client jar 22 MB;
  - the 38 classpath libraries the planner expects (the other 50 JSON entries are LWJGL/natives, excluded on purpose);
  - the asset index.

  The downloader verifies SHA-1 before moving each file into place, so presence implies a verified file. This is the first full-size real-network install verified on a device. The app stayed in the foreground; background behaviour is still untested.
- **The user reported "it cannot open the game version".** `launcher.log` shows "Prepare launch plan" tapped 4× for 1.20.1 (missing files: 0) and once for 1.21.11. That is the intended limit of this build: it only builds the JVM command line. There is no JVM, LWJGL or GL layer, so nothing can start the game. The UI should say this more clearly.
- **Milestone 5, first JVM attempt on device (13:59 UTC):** StikDebug 3.1.9 failed on iOS 27 ("DDI mount failed", "connection error"). This matches StikDebug issues #464 and #469, fixed in 3.1.11. The user updated to 3.1.14 and rebooted, and StikDebug connected.
  - Launched from StikDebug: `CS_DEBUGGED=1`, and libjvm **loaded** (the bundled, Sideloadly-signed dylibs are accepted).
  - `JNI_CreateJavaVM` reached `Threads::create_vm` → `initialize_java_lang_classes`, then **crashed**: `JavaCalls::call_helper`, KERN_INVALID_ADDRESS at 0xd8, HotSpot `report_and_die` (crash file `ZalithIOS-2026-10-15-205920.ips`).
  - Cause, from disassembly of the bundled libjvm: `get_debug_jit_mapping` (with MirrorMappedCodeCache on iOS ≥ 19) calls `dlsym(RTLD_DEFAULT, "DeviceHasTXM")`, falling back to env `XNU_HAS_TXM=1`. Only if that is true does it request the code cache from the debugger via `BreakGetJITMapping` (`brk #0x69`); otherwise it uses plain `mmap`. The app exported neither, so the JVM ran with an unusable code cache.
  - My `needsScript` also required the "mirrored" flag (it was 0), so the extension script was never sent. `getppid()` said "no debugger" while StikDebug was attached, so it is not a reliable check here.
  - Also, two later normal launches wiped `jvm.log`, so HotSpot's own output from the crash is lost.
- **Fixes:**
  - export `DeviceHasTXM()` (verified in the export trie: `_DeviceHasTXM`) and set `XNU_HAS_TXM=1`;
  - TXM alone now triggers the JIT26 sequence;
  - the `brk #0x69` probe runs under a temporary SIGTRAP handler, so a missing debugger gives an error instead of a crash (handler verified on macOS arm64 only, not on iOS);
  - `jvm.log` is appended per run;
  - `-XX:ErrorFile` points to `logs/`.

  New IPA SHA-256 `e2467211…1fc2`. Not yet tested on the device.

## 2026-10-16
- **Retest with the fixed IPA (00:05 and 00:08 UTC):** launched from StikDebug 3.1.14, `CS_DEBUGGED=1`. Both runs **stopped safely before the JVM**: `jvm.log` says "JIT26 probe: no debugger caught the breakpoint". The SIGTRAP fallback worked on iOS 27, and there was no crash.
  - StikDebug granted JIT, but no JIT script was attached at that point.
- **Why, from StikDebug source (HEAD):**
  - `ScriptStore` keeps manual script assignments per bundle ID in UserDefaults.
  - `AutoScriptAssignments.swift` auto-assigns the built-in `universal.js` only to a fixed list of app names (Amethyst, MeloNX, UTM, …). "Zalith iOS" is not on it, so without a manual assignment StikDebug just enables JIT and detaches.
  - StikDebug's built-in `universal.js` (header dated 2026-03-29) is the same protocol as Amethyst's `UniversalJIT26.js`, plus a `continuesWithSignal` option.
- **Side observation:** the reinstall gave the app a new data container (`789D87E2…`), and the user was re-downloading game files. A brief network drop caused retried downloads (`NSURLErrorDomain -1005`). The retry logic handled it as designed.
- **The script was not visible in StikDebug 3.1.14's swipe actions.** From its source (`InstalledAppRows.swift`), "Assign Script" is in the long-press context menu of the app row on the Home tab. It only shows when `enableAdvancedOptions` is set, which defaults to on for iOS ≥ 19. The user assigned the built-in `universal.js` that way.
- **MILESTONE 5 PASSED ON DEVICE (00:16 UTC):** full output in `docs/evidence/2026-10-16-java-smoke-test.log`.
  - Probe answered `0x…690000e0` (universal script), and the extension was sent.
  - libjvm logged "Requesting 240 MB for JIT mapping", "Got JIT mapping 0x11e6b4000 from debugger", and the mirrored RW/RX mapping.
  - OpenJDK 64-Bit Server VM 17.0.20 started in-process with 6 CPUs and maxMemory 256 MB.
  - The hot loop took 9 ms (16 ms on the M4 Mac with JDK 26). This is consistent with JIT compilation, not proof of it; no `-XX:+PrintCompilation` run yet.
  - A worker thread ran, and the program printed `ZALITH_JAVA_OK`; `main` returned normally.
  - The app was still running afterwards (PID 1862), with no hs_err file and no new crash report.
  - The two other crash reports (2026-10-15 21:00:46 and 2026-10-16 06:49:20) both predate this build and have the same HotSpot abort signature as the first crash.
- **Still unverified:**
  - a second JVM run per process (JNI does not allow it);
  - long runs and memory pressure under a free account (no increased-memory entitlement);
  - what happens after StikDebug detaches when more code-cache space is needed. The debugger detaches after the single mapping request, so the 240 MB reservation must last the whole run.
- **Milestone 6 step 1: GL layer choice (from source):**
  - Amethyst's iOS renderers: gl4es (desktop GL ≤ 2.1, too old for 1.20.1), MobileGlues (GL 4 → GLES 3, links `-framework libEGL -framework libGLESv2`, i.e. ANGLE), tinygl4angle (desktop GL on ANGLE), and Zink.
  - Every 1.20.1-capable path sits on **ANGLE**. Upstream ANGLE rejects desktop GL (`validationEGL.cpp`: "Desktop GL is not supported by ANGLE"), so step 1 targets OpenGL ES 3 on ANGLE/Metal. Desktop GL comes later from MobileGlues.
  - The iOS 27 SDK still ships the deprecated `OpenGLES.framework`; it is not used.
- **ANGLE built from source:**
  - depot_tools `382c208`; upstream ANGLE `33f8caff4b77667bc50d8484401af01291de119d` (2026-10-15).
  - gn args adapted from AngelAuraMC/angle `out/ios-arm64/args.gn`: Metal only, release, no tests. `angle_enable_d3d9` was dropped (no longer exists upstream).
  - First `gclient sync` hit a gsutil lock race in hooks. A resumed sync with `-j 4` succeeded (12 GB checkout). `ensure_bootstrap` was needed because `DEPOT_TOOLS_UPDATE=0`.
  - `autoninja libEGL libGLESv2` took 406 s on the M4, producing `libEGL.framework` (118 KB) and `libGLESv2.framework` (5.9 MB): arm64, platform iOS, minOS 18.0, linking only system frameworks.
  - libEGL loads `<exe dir>/Frameworks/libGLESv2.framework/libGLESv2` at runtime (`system_utils_posix.cpp` + `system_utils_ios.cpp`); the bundle layout matches.
  - Reproducible with `scripts/build-angle.sh`.
- **Graphics test (native, no Java):** `GLTest.m`, Diagnostics → "Run graphics test". It uses an EGL platform display (ANGLE Metal) on a CAMetalLayer view and a GLES 3.0 context, draws 120 frames, and checks pixels with glReadPixels (centre triangle, corner clear colour), logging `ZALITH_GL_OK` to `logs/gl.log`.
  - IPA (step 1 only): `build/ipa/ZalithIOS-m6step1-unsigned.ipa`, SHA-256 `18ba50ef…aac3`, 39.4 MB.
  - **Not yet tested on the device** (user's phone unavailable).
- **Milestone 6 step 2: LWJGL 3.3.3 built from source** (`scripts/build-lwjgl.sh`):
  - **Source:** AngelAuraMC/lwjgl3 `wip/rebase_3.3.3` at `6a564a8b4b14` (BSD-3-Clause, PojavLauncher lineage). Its `config/macos/build.xml` targets the iPhoneOS SDK, and generated sources are committed, so the Kotlin generator is skipped.
  - **Tools:** Apache Ant 1.10.18, SHA-512 verified against Apache's published hash.
  - **libffi 3.4.8,** SHA-256 matching Homebrew's formula. 3.4.6, which the fork's CI uses, fails to assemble `sysv.S` with Xcode 27 clang ("invalid CFI advance_loc expression"). Its Xcode project needed `IPHONEOS_DEPLOYMENT_TARGET` raised (8.0 is rejected) and empty armv7 header placeholders.
  - **Build fixes:**
    - LWJGL 3.3.3 only recognises JDKs ≤ 21, so on JDK 26 `jni.headers` is passed explicitly.
    - `yes | ant` SIGPIPE under pipefail is fixed.
    - The minimum iOS version is set to 16.0 to match the app.
  - **Natives built for iOS** (platform 2, minOS 16.0, linking only libSystem and CoreFoundation, libffi static): `liblwjgl` (1793 JNI exports), `liblwjgl_opengl`, `liblwjgl_opengles` (872 JNI exports), `liblwjgl_stb`, `liblwjgl_tinyfd`.
  - **Jars:** lwjgl, egl, glfw, jemalloc, openal, opengl, opengles, stb, tinyfd. Built in "JDK 8 mode", so without the optional Java 9 multi-release classes.
  - **Caution:** the `release` target also *downloads* official macOS/Linux/Windows natives from build.lwjgl.org (e.g. macOS `libglfw`, `libopenal`, `libjemalloc`, platform 1). The script copies only the five iOS natives and refuses any non-iOS binary.
  - **Fork quirk:** `org.lwjgl.system.Library`'s static initialiser does `System.load($BUNDLE_PATH + "/AngelAuraAmethyst")` on macOS (Amethyst's GLFW bridge). It is caught as UnsatisfiedLinkError here, so it's harmless for the GLES test, but step 3 (GLFW bridge) must patch it.
- **Java graphics test** (`JavaTest/gles/…/LwjglGlesSmokeTest.java`, Diagnostics → "Run Java graphics test (LWJGL → ANGLE)"): LWJGL EGL bindings on ANGLE's libEGL (Metal platform display), a 256×256 pbuffer, a GLES 3.0 context through LWJGL's GLES bindings, a triangle, and `glReadPixels` checks → `ZALITH_LWJGL_GLES_OK`.
  - Uses `-Dorg.lwjgl.librarypath`, `-Dorg.lwjgl.system.allocator=system`, and LWJGL debug logging.
  - Could not run on macOS (iOS-only natives; no macOS ANGLE build).
- **IPA with both step-1 and step-2 tests:** `build/ipa/ZalithIOS-unsigned.ipa`, 42185688 bytes, SHA-256 `c8d459c89f74ad6a75536066b2694b3e186182db847523b25be00ed103849435`. All 38 Mach-O libraries in the app are platform iOS, with no symlinks. **Neither graphics test has run on a device yet.**
- **MILESTONE 6 STEP 1 PASSED ON DEVICE (15:02 UTC, IPA `c8d459c8…9435`):** native ANGLE test (`docs/evidence/2026-10-16-angle-gl-test.log`).
  - EGL 1.5 "Google Inc. (Apple)", `GL_RENDERER=ANGLE (Apple, ANGLE Metal Renderer: Apple A17 Pro GPU, Version 27.0 (Build 24A437))`, OpenGL ES 3.0 / GLSL ES 3.00, git hash `33f8caff4b77`, i.e. our build.
  - Surface 1290×2796. Read-back: centre (255,128,0,255), corner (26,77,153,255), glError 0. 120 frames in 2.03 s (59.2 fps). `ZALITH_GL_OK`.
  - It ran without JIT being required (it was launched from StikDebug anyway).
- **Step 2 first device run (15:02 UTC): FAILED in my test code, not in LWJGL.**
  - JIT mapping obtained; LWJGL 3.3.3 loaded `liblwjgl.dylib` from `org.lwjgl.librarypath`; LWJGL's EGL binding loaded ANGLE's libEGL ("Success").
  - Then `IllegalStateException: EGL has already been created`: `EGL`'s static initialiser auto-creates unless `Configuration.EGL_EXPLICIT_INIT` is set, and the test called `EGL.create()` again. Fixed by setting `EGL_EXPLICIT_INIT`.
  - Also logged: the expected caught `UnsatisfiedLinkError` for `null/AngelAuraAmethyst` (fork quirk).
  - Also logged: "[LWJGL] [ERROR] Incompatible Java and native library versions". This is a warning only (`Library.checkHash` prints and continues). The jars carry SHA-1s of the official natives downloaded by the release step (`aca9d32c…` vs our iOS `b4144326…`). `build-lwjgl.sh` now strips `META-INF/*.sha1|*.git` from the jars.
  - Rebuilt IPA SHA-256 `83fc0631a78f2decfc18f308693b71ec8a2b9130394969bb933eaded7134270c`; **step 2 not yet re-run.**
- **Step 2 second device run (15:09 UTC, IPA `83fc0631…`, new install folder `0FF9017C`):** the hash warning is gone, and EGL now loads once ("Loading library …/libEGL … Success").
  - Failed with an NPE in `Checks.check` inside `EXTPlatformBase.neglGetPlatformDisplayEXT`. LWJGL's generated `eglGetPlatformDisplay(EXT)` wrappers require a non-NULL `native_display`, but `EGL_DEFAULT_DISPLAY` is NULL (valid for ANGLE, and the native test uses it).
  - Fixed by calling the function pointer through `JNI.callPPP`, exactly what the wrapper does after its checks.
  - Audited the other EGL wrappers the test uses: they only check `dpy`/`config`, which are non-NULL there.
  - Rebuilt IPA SHA-256 `79c3d60807ef48b5a7d216b787c26d2f29e43b149b630b7e803c91d8feb52d9e`. **Re-run pending.**
- **MILESTONE 6 STEP 2 PASSED ON DEVICE (15:16 UTC, IPA `79c3d608…2d9e`):** full log in `docs/evidence/2026-10-16-lwjgl-gles-test.log`.
  - JIT mapping obtained; LWJGL 3.3.3 loaded our iOS `liblwjgl.dylib` and `liblwjgl_opengles.dylib` plus ANGLE's libEGL/libGLESv2.
  - EGL 1.5 "Google Inc. (Apple)", `GL_RENDERER=ANGLE (Apple, ANGLE Metal Renderer: Apple A17 Pro GPU …)`, `GL_VERSION=OpenGL ES 3.0 (ANGLE 2.1.1 git hash: 33f8caff4b77)`, GLES30=true.
  - Offscreen 256×256 pbuffer read-back: centre (255,128,0,255), corner (26,77,153,255), glError 0 → `ZALITH_LWJGL_GLES_OK`; `main` returned normally.
  - **Java → LWJGL → ANGLE → Metal works on device.**
  - Remaining for step 3: GLFW bridge (window/input), patching the fork's `AngelAuraAmethyst` load, and desktop GL for Minecraft via MobileGlues.
- **Milestone 6 step 3a: MobileGlues built from source** (`scripts/build-mobileglues.sh`):
  - **MobileGlues** `f0fb4d32794a`, the commit Amethyst-iOS pins (HEAD has been restructured), LGPL-2.1.
  - **Shader toolchain:** glslang 15.0.0 (matching MobileGlues' bundled `build_info.h`); SPIRV-Tools `6dcc7e35` and SPIRV-Headers `2a9b6f95` (pinned by glslang's `known_good.json`); SPIRV-Cross `vulkan-sdk-1.4.304.0` (C API 0.64, matching MobileGlues' headers; its bundled dylib is misnamed 0.65).
  - **Submodules:** glm `2d4c4b4d`, xxhash `c2866db3`, FastSTL `644b3b01`. Perfetto is skipped (profiling only).
  - **Build tool:** CMake 4.4.4, SHA-256 checked against Kitware's checksum file (the GPG signature was not checked).
  - **Replaced prebuilts:** MobileGlues' own prebuilt `libraries/ios` binaries and `external/libEGL.framework` stub are deleted and replaced with these builds and our ANGLE frameworks.
  - **Result:** `libmobileglues.dylib` (7.5 MB, iOS, minOS 16.0) links our ANGLE frameworks and `libspirv-cross-c-shared.0.dylib` through @rpath. It exports 6142 symbols, including desktop GL, glX and EGL entry points. The build-tree rpath was stripped.
- **MobileGlues facts relevant to integration:**
  - On Apple it resolves GLES through `dlsym(RTLD_NEXT)` against the linked ANGLE frameworks.
  - It initialises in a static constructor (`init.cpp` → `proc_init`) that queries GLES, so an EGL context must be current when it is loaded.
  - It reads config and log location from `MG_DIR_PATH`.
  - It cannot be re-initialised per process.
- **Licence gap:** FastSTL (header-only, compiled into MobileGlues) has no licence file and no declared licence. This is OK for private device testing and **blocks public distribution** until clarified with MobileGL-Dev.
- **Step 3b (native) and 3c (Java) desktop GL tests built:**
  - Diagnostics → "Run desktop GL test (MobileGlues)": the ANGLE ES 3.x context (3.2 → 3.1 → 3.0 tried), MobileGlues loaded while current, `#version 330 core` shaders, pixel read-back → `ZALITH_DESKTOPGL_OK`.
  - "Run Java desktop GL test": LWJGL `GL.createCapabilities()` with `-Dorg.lwjgl.opengl.libname=…/libmobileglues.dylib`, GL33C calls → `ZALITH_LWJGL_DESKTOPGL_OK`.
  - IPA SHA-256 `0dce982ef5c6d8874bd6cf2f94297f7f37f62bee6b10b3075e2625d69d509c7c`; all 40 Mach-O libraries are iOS. **Not yet run on a device.**
- **Steps 3b/3c first device runs (15:38–15:39 UTC, IPA `0dce982e…`): inconsistent, as the user also observed.**
  - **Working:** MobileGlues loads and reports `GL_VERSION=4.0.0 MobileGlues 1.3.3` and `GLSL 4.00 MobileGlues with glslang and SPIRV-Cross`. LWJGL sees OpenGL32/33/40=true. ANGLE grants only a GLES **3.0** context (3.2/3.1 refused).
  - **Native runs (gl.log, by launch):**
    - launch A: first run `eglSwapBuffers failed at frame 1: 0x300D`, second run nothing drawn;
    - launch B (after the Java test): one run **passed with exact pixels** (`ZALITH_DESKTOPGL_OK`), then later runs drew nothing.
  - **Java run:** corner = clear colour, centre = (97,110,115,102), which is garbage.
- **Cause, from MobileGlues source:**
  - `init_target_egl()` (run from the load-time static constructor) creates a temporary 32×32 ES2 pbuffer context on the default display and makes it **current**.
  - On Android `destroy_temp_egl_ctx()` removes it later; on Apple that call is `#ifndef __APPLE__`'d out and the caller's context is never restored.
  - So loading MobileGlues silently replaced the host's current context. The Java test drew into MobileGlues' 32×32 pbuffer, and reading at (128,128) is outside it, hence garbage. The native test's surface was no longer current, hence BAD_SURFACE.
  - **Fix:** `patches/mobileglues/0001-apple-restore-caller-egl-context.patch`, applied by `build-mobileglues.sh`. On Apple it saves the caller's EGL display/surfaces/context before init, then unbinds and destroys the temp context (no `eglTerminate`) and restores the caller's context.
- **Second effect (hypothesis, consistent with all runs, not proven):** MobileGlues keeps process-wide GL bookkeeping that cannot be reset, so only the first context it serves per process behaves. Later contexts reuse the same object names and draw nothing.
  - Minecraft uses one context per launch, so the app now allows **one MobileGlues test (native or Java) per launch**.
- **IPA** SHA-256 `d3f149c58be40f63b3aeb3df1f37e5eb745194b80ccb3e5e1baaeeec89822944`. **Not yet re-tested.**
- **Re-test 15:47 UTC (install folder `EFB49F27`): the patched build was most likely NOT installed.**
  - The Java desktop-GL run failed with the identical unpatched signature, centre (97,110,115,102).
  - The native desktop-GL run happened in the same process (PID 3898, no new app start) right after the Java run, which the patched build's one-MobileGlues-test-per-launch guard would block. It **passed** (`ZALITH_DESKTOPGL_OK`), again as the second MobileGlues use in its process.
  - Probable cause: an older copy (`ZalithIOS-m6step3bc-unsigned.ipa`) next to the current IPA.
- **Changes:**
  - `build-ipa.sh` now stamps a unique UTC build number into CFBundleVersion, shown in `devicectl device info apps`, and the app logs it at startup.
  - Older IPA copies moved to `build/ipa/old/`.
  - New IPA: build `202610161548`, SHA-256 `7c8972e481848a0fba558213e045e62b352f140f26deb4fcd74a07effe15567d`, patched MobileGlues confirmed by its exported `save_caller_egl_ctx`/`restore_caller_egl_ctx`.
- **MILESTONE 6 STEPS 3b + 3c PASSED ON DEVICE (15:52 UTC, build `202610161548` confirmed via `devicectl device info apps`):**
  - **3b, native, own launch:** MobileGlues 1.3.3 reported GL 4.0.0 on ANGLE GLES 3.0 / Metal / A17 Pro. A `#version 330 core` triangle drew at 59.3 fps with exact read-back (255,128,0 / 26,77,153), giving `ZALITH_DESKTOPGL_OK` (`docs/evidence/2026-10-16-mobileglues-native-desktopgl.log`).
  - **3c, Java, separate launch:** LWJGL 3.3.3 loaded MobileGlues as its OpenGL library; caps OpenGL32/33/40=true. GL33C calls drew with exact read-back, giving `ZALITH_LWJGL_DESKTOPGL_OK` (`docs/evidence/2026-10-16-lwjgl-desktopgl-test.log`).
  - The context-restore patch fixed the Java path, which failed deterministically without it.
  - **Java → LWJGL desktop GL → MobileGlues → ANGLE → Metal works on device:** the graphics path Minecraft 1.17+ needs.
  - **Still open:** ANGLE grants only GLES 3.0 (no 3.1/3.2), so MobileGlues lacks multi-draw-indirect, compute and GL43 extras. The GLFW window/input bridge (3d) is next.
- **Milestone 6 step 3d: GLFW bridge implemented** (`App/ZalithIOS/Native/ZLGLFW.m`). Not yet run on a device.
  - **How it plugs in:** the fork's `org.lwjgl.glfw.GLFW` is LWJGL's standard binding. It resolves 117 required `glfw*` functions via `apiGetFunctionAddress` from `-Dorg.lwjgl.glfw.libname`. Like Amethyst, we point that at the app executable, which exports a GLFW 3.4 implementation compiled against upstream `glfw3.h` (tag 3.4, zlib). The export trie of build `202610161603` contains **117/117**.
  - **Windows and context:** the first window is a full-screen `UIWindow` (level normal+1) with a CAMetalLayer view and an ANGLE EGL ES 3.x context, made current with `glfwMakeContextCurrent`. Desktop GL comes from MobileGlues (LWJGL's OpenGL library). Further or invisible windows use pbuffers and shared contexts.
  - **Sizes and platform:** window size in points, framebuffer in pixels; `ZALITH_RENDER_SCALE` env (0.1–1.0) can lower render resolution. `glfwGetPlatform` = `GLFW_PLATFORM_NULL`, to keep Cocoa/AppKit paths away.
  - **Input:** queued from UIKit and delivered in `glfwPollEvents`/`glfwWaitEvents`.
    - One finger = cursor + left button; a second finger = right button.
    - `GLFW_CURSOR_DISABLED` switches to relative (mouse-look) deltas; a three-finger tap triggers window close.
    - Hardware keyboard: `UIPress` HID usage → GLFW keys, `UIKey.characters` → char callbacks.
    - Joysticks are not implemented.
  - **Requirements:** needs `-Dorg.lwjgl.glfw.checkThread0=false`, because calls come from the JVM thread.
  - **Startup check:** the app now logs a self-check, `dlopen(executable)` + `dlsym(glfwInit)`, because dlopen-ing the main executable is assumed (Amethyst relies on it) but **not yet verified on iOS 27**.
  - **Java test:** `GlfwSmokeTest` requests 3.2 core / forward-compatible hints as Minecraft does, creates the window, runs `GL.createCapabilities()` through MobileGlues after `glfwMakeContextCurrent` (the real load order), and runs an interactive 30 s loop with frame-5 read-back → `ZALITH_GLFW_OK`.
- **MILESTONE 6 STEP 3d FIRST DEVICE RUN (16:07 UTC, build `202610161603`): `ZALITH_GLFW_OK`** (`docs/evidence/2026-10-16-glfw-bridge-test.log`).
  - Startup self-check: `dlopen(executable) ok; glfwInit=ok glfwSwapBuffers=ok`, so **iOS 27 allows dlopen-ing the main executable**.
  - LWJGL's GLFW bound to the app executable: `GLFW 3.4.0 Zalith iOS`, platform 0x60005 (NULL).
  - The window was on-screen, 430×932 pt / 1290×2796 px, on a 120 Hz display.
  - `glfwMakeContextCurrent` → `GL.createCapabilities()` loaded MobileGlues **with our context still current afterwards** (`current context ok=true`). This is Minecraft's real order, and it confirms the context-restore patch.
  - GL 4.0 core; frame-5 read-back exact; **1815 frames in 30.0 s (60.5 fps, swap interval 1)**; mouse-button callbacks delivered (6).
  - **Problems:**
    - (1) Only 3 cursor events (one per touch-down), but the user later said they probably did not drag, so this is **not a confirmed bug**. Touch-phase counters were added to settle it next run.
    - (2) The three-finger-tap exit never fired. iOS reserves three-finger taps for system undo/redo editing gestures, which was a poor choice; it needs an explicit close control.
    - (3) Portrait framebuffer, while Minecraft expects landscape.
- **GLFW bridge follow-up:** build `202610161611` (SHA-256 `45d31cecb758bea6baa4d707ca97a8ee7dc90f468285796c39e8e177b85d9185`).
  - Adds a ✕ close button on the game window (sends a GLFW close request).
  - The game window requests landscape (iOS 16+ geometry request).
  - Adds touch-phase counters logged on window destroy, which land in jvm.log.
  - 117/117 GLFW exports; all bundled libraries are iOS. Not yet run on a device.
- **GLFW re-test with drags (16:18 UTC, build `202610161611`): `ZALITH_GLFW_OK`** (`docs/evidence/2026-10-16-glfw-input-test.log`).
  - **Drags work:** `touches: began=8 moved=1507 movedAccepted=1470 ended=8 cancelled=0`, giving 1476 cursor callbacks and 16 mouse-button callbacks in Java. The earlier "3 cursor events" were taps only.
  - **Landscape works:** framebuffer 1290×2796 → 2796×1290, delivered through the framebuffer-size callback.
  - 1792 frames in 30.0 s (59.7 fps), exact read-back.
  - **Close button: not confirmed.** The run lasted the full 30 s and all 8 touches reached the game view, none the ✕ button. Either the tap missed the button or came after the timer.
- **Close button confirmed (16:21 UTC, build `202610161611`):** the run ended after **5.9 s** (359 frames, 60.8 fps) when the user tapped ✕, so the GLFW close request reached `glfwWindowShouldClose` (`docs/evidence/2026-10-16-glfw-close-button.log`). The earlier full-30 s run was a tap after the time limit, as the user clarified.
  - Same run: 1 drag gave 229/229 moves accepted and 230 cursor callbacks; landscape rotation and pixel read-back OK.
  - **Milestone 6 step 3d verified on device:** window, context, MobileGlues in the real load order, touch→mouse input, landscape and close.
  - **Not yet covered:** hardware keyboard (no keyboard attached), scroll and touch controls for gameplay, joysticks.

## 2026-10-16 — Milestone 7 (first Minecraft launch attempt) preparation
- **Device data:** after the latest reinstalls the app's data container held **no game files**; Sideloadly reinstalls appear to wipe app data.
  - 1.20.1 is now installed on the Mac with `zalith-cli install 1.20.1 --root build/gamedata` (3616 files, all hash-verified, 720 MB).
  - `scripts/push-gamedata.sh` copies it to the phone with `devicectl device copy to`.
- **What 1.20.1 needs beyond Milestone 6** (found in the real client jar):
  - `ehg` (MacosUtil) uses `GLFWNativeCocoa.glfwGetCocoaWindow` and the macOS-only `ca.weblite.objc` bridge. Its icon path (`NSApplication setApplicationIconImage`) runs unconditionally at start-up on "Mac OS X", so it would throw `NoClassDefFoundError`.
    - Fix: our own no-op `ca.weblite.objc.{Client,Proxy,NSObject}` (`JavaRuntime/ios-compat`, written from the call signatures, not copied).
    - The fullscreen path stays inert because our `glfwGetCocoaWindow` returns NULL.
  - **OpenAL:** the sound engine uses LWJGL OpenAL, and a missing native fails in a static initialiser.
    - Fix: openal-soft **1.25.2** built from source (`scripts/build-openal.sh`, CoreAudio backend), 1.6 MB, iOS, system frameworks only, 186 exports.
    - Xcode 27 needed `HAVE_WFUNCTION_EFFECTS=OFF` + `-Wno-error=function-effects`, and `HAVE_LIBATOMIC=OFF`.
  - **oshi/JNA:** `GLX._init` wraps the oshi CPU probe in `catch (Throwable)`, so a JNA failure is tolerated.
  - **Narrator:** `text2speech` `Narrator.getNarrator()` catches `Throwable`.
  - The GLFW bridge now also exports the 7 native-access functions (`glfwGetCocoaWindow/Monitor`, `glfwGetNSGLContext`, `glfwGetEGL*`).
- **Launch path** (`MinecraftLauncher.swift`, Versions → installed version → "Launch Minecraft (experimental)"):
  - **Classpath:** LaunchPlanner classpath + iOS LWJGL modules + compat jar.
  - **JVM args:** version-JSON args minus `-cp` (JNI) and the log4j XML config, plus the LWJGL/HotSpot flags verified in Milestones 5–6.
  - **Heap:** capped at 40% of `os_proc_available_memory`.
  - **Render scale:** `ZALITH_RENDER_SCALE=0.5` default.
  - Build `202610161636` (SHA-256 `acf7459f9de1de007a65a9332cf963b4770ea1eb93d8431d0adb030cd812053f`). **Not yet run.**
- **MILESTONE 7: MINECRAFT 1.20.1 RAN ON THE IPHONE AND THE PLAYER JOINED A WORLD (16:42–16:43 UTC, build `202610161636`)** (`docs/evidence/2026-10-16-minecraft-1.20.1-first-launch.log`):
  - **Start-up:** game files pushed from the Mac (`push-gamedata.sh`: 3575 assets, 38 libraries, client jar, counts matching the Mac). JIT mapping from StikDebug; heap 1335 MB (40% of available); 47 classpath entries.
  - **Init:** `Backend library: LWJGL version 3.3.3`. The GLFW window "Minecraft 1.20.1" was 430×932 pt with a 645×1398 px framebuffer (render scale 0.5), then MobileGlues initialised.
  - **Sound:** "OpenAL initialized on device CoreAudio Default" → "Sound engine started" (openal-soft 1.25.2).
  - **Resources:** atlases created and the vanilla resource reload completed (Minecraft shaders compiled through MobileGlues; glsl cache 70 KB).
  - **Into the world:** the user reached the title screen and created a world. The integrated server started and spawn preparation took 25.8 s; then "Player joined the game" at (55.5, 64, 33.5). GLFW cursor capture (`GLFW_CURSOR_DISABLED`) was engaged and touch drags were delivered (240 moves, 15 touches).
  - **Performance:** one "Can't keep up! … 40 ticks behind" warning on the integrated server.
  - **Exit:** "Stopping!" at 16:43:41 (window close from the ✕ button). The world was **saved cleanly** (all dimensions) and the process exited.
  - **No crashes or unexpected errors.** Expected or harmless noise:
    - 401 auth / Realms (offline account);
    - oshi/JNA `UnsatisfiedLinkError`, caught by `GLX._init`;
    - the fork's `AngelAuraAmethyst` load attempt, caught;
    - vanilla goat-horn sound and sampler warnings.
  - **Our bug:** log4j could not open `logs/latest.log`, because the process cwd is `/`.
  - **Not measured:** FPS and visual correctness. The user needs to report what was on screen.
- **Fix:** Minecraft is now launched with cwd = game dir and `-Duser.dir=<game dir>`, in build `202610161645` (SHA-256 `39a392c8d8a8326370c97d9d9d5efb760e6e8a30bb93ac67c964e84e00225108`). Not yet run.
- **User feedback after the first launch:** no sound, and no way to control the game (only mouse emulation).
  - **Sound, likely cause (not verified):** the app never configured an AVAudioSession, so iOS used solo-ambient, which the silent switch/Action button mutes. `MinecraftLauncher` now sets `.playback` + `.mixWithOthers` and activates it before launch. Not built or tested yet.
  - **Controls, work in progress (uncommitted, NOT built):** `ZLGLFW.m` now holds a first-draft overlay (joystick, buttons, keyboard proxy, in-game gestures: drag = look, tap = use, long press = break). The user asked for **Amethyst/PojavLauncher's default layout plus haptic feedback**, so the draft layout must be replaced.
- **Amethyst default layout (from Amethyst-iOS `Natives/customcontrols/CustomControlsUtils.m`, `generateAndSaveDefaultControl`, GPL-3.0):**
  - **Expression variables:** `${screen_width}`/`${screen_height}` in px (points × UIScreen.scale); `px(x)` = scale·x; `${margin}` = 2·scale; `${preferred_scale}` = pref `control.button_scale` (default 100); `${width}`/`${height}` = button size·scale.
  - **Style:** bgColor 0x4d000000, cornerRadius 100 (fully rounded), stroke white, strokeWidth 0 (drawer 1.5), multi-line titles.
  - **Buttons (name, key, size in pt, toggle, inGame, inMenu):**
    - Jump: SPACE, 69.6², x≈0.9488·W−69.6, y≈0.3113·H+69.6+m; game only.
    - Shift: LEFT_SHIFT, 69.6², toggle, same x as Jump, y≈0.3113·H; game + menu.
    - Sprint: LEFT_CONTROL, 69.6², toggle, left of Shift (x − w − m), y≈0.3113·H; game only.
    - Right Click: mouse 2, 69.6², x=0.8756·W−w, y=0.8178·H−h, swipeable.
    - Left Click: mouse 1, 69.6², x=0.7756·W−w, y=0.8225·H−h, swipeable.
    - Middle Click: mouse 3, 69.6², x=0.8355·W−w, y=0.6780·H−h, swipeable.
    - Top row at y=0, packed from the right edge:
      - Runtime Menu: special menu, 104.8×39.2.
      - Hide GUI: special toggle-controls, 69.6×40.
      - Pause: ESC, 104.8×39.2, game only.
      - Inventory: E, 100×40, game only.
      - Exit Menu: ESC, 104.8×39.2, menu only.
    - Drawer "More" at (0,0), 96×40, opening a FREE drawer with Third person (F5), Debug Menu (F3), Mouse Toggle (virtual mouse), Chat (T), Keyboard (show iOS keyboard), Player List (TAB, toggle), each 96×40.
    - Joystick: bottom-left, x=0.0233·W, y=0.9753·H−h, 204.8², not absolute, no forward lock; game only.
  - **Haptics:** `UIImpactFeedbackGenerator` light on button touch-down (`executebtn_down`), surface tap and scroll; medium on long press. Disabled by pref `control.disable_haptics` (default NO).
- **Next steps:**
  1. Replace the draft layout with the Amethyst default above, plus light/medium haptics.
  2. Build and verify.
  3. Re-test sound (with silent mode on and off) and controls on the device.
  4. Fix the cwd/log4j issue; already done in `MinecraftLauncher` (build `202610161645`).

## 2026-10-17 — Controls and sound
- **On-screen controls rebuilt on Amethyst's default layout** (positions from its `generateAndSaveDefaultControl` expressions, evaluated in points with button_scale 100, margin 2 pt):
  - Jump, Shift (toggle) and Sprint (toggle); Left/Right/Middle Click.
  - Top row: Runtime Menu, Hide GUI, Pause, Inventory, Exit Menu (menu only).
  - "More" drawer: Third person, Debug Menu, Mouse Toggle, Chat, Keyboard, Player List.
  - 204.8 pt joystick bottom-left.
  - Per-button in-game/in-menu visibility as in Amethyst; style 0x4d000000, fully rounded.
  - Player List is moved into the free top drawer slot, because Amethyst's expression places it at y < 0.
- **Special buttons:**
  - Runtime Menu: action sheet with keyboard, virtual mouse, and "Quit game (saves the world)", which replaces the ✕ button.
  - Hide GUI: hides everything but itself.
  - Mouse Toggle: trackpad-style pointer in menus, drawn with the SF Symbol `cursorarrow`.
  - Keyboard: iOS keyboard → GLFW char/Backspace/Enter.
- **Surface gestures:**
  - In game: drag = look, tap = use (right click), long press = break (hold left), tap on a hotbar slot = keys 1–9 (auto GUI scale assumed).
  - In menus: direct pointer.
- **Haptics (as Amethyst):** `UIImpactFeedbackGenerator` light on every button press, joystick touch and surface tap; medium when a long press starts.
- **Sound:** `AVAudioSession` set to `.playback` + `.mixWithOthers` and activated before launch.
- **Working directory:** Minecraft's cwd and `user.dir` are now the game dir.
- **Build `202610170052`** (SHA-256 `4ebd8ba86a02323f93c5d2e059f721dec08adb5f78715f1db7cdf2ea3638ced4`): 124 GLFW exports, 56/56 core tests passing. **Not yet run on device.**

## 2026-10-17 — Device test of build 202610170052
- **Evidence:** launcher.log, jvm.log and minecraft/logs/latest.log pulled from the device; the user's report.
- **Run 01:01:06Z:** Minecraft 1.20.1 with a 1335 MB heap.
  - OpenAL initialised on "CoreAudio Default" and the sound engine started.
  - The player joined a world at 01:01:21; 22 touches were recorded.
  - The user left with Save and Quit. The world was saved at 01:02:27 and "Stopping!" logged at 01:02:31.
  - **No crash report for this run**, so the process ended cleanly.
- **User report:**
  - Sound works.
  - The controls work and look right.
  - **The Inventory button was missing.**
- **Inventory position fix:** simplifying Amethyst's x expression gives W − 69.6 − 2·104.8 − 100 − 3·2, i.e. directly left of Pause. My earlier version had used 3·104.8 + 4·2. That put the button 107 pt too far left (x≈440 on a 932-pt screen), but still on screen. **The wrong position alone does not explain why the button was missing, so the cause is still unconfirmed.**
- **Added diagnostic:** a `[ZLGLFW] controls WxH, inGame=…, top row: …` line, logged on every overlay resize and every switch between game and menu. It records each top-row button's x, width and hidden state.
- **Two earlier crash reports (08:00:29 and 08:00:49 local)** come from earlier sessions, not this run: FRONTBOARD 0x8BADF00D "Failed to terminate gracefully after 5.0s", a process-exit watchdog. They are open; the likely cause is closing the app while the JVM is running.
- **Expected, harmless errors in latest.log:**
  - The JNA/oshi native library is not available on iOS (hardware info query).
  - LWJGL's `null/AngelAuraAmethyst` probe.
  - Offline-account 401s from authlib and Realms.
- **Build `202610170108`** (SHA-256 `0d25bbb560afaa2c71b8ab43cf40b89de9f26ed41f80e0c5e85144ee1b60a7e4`). **Not yet run on device.**

## 2026-10-17 — Inventory button moved to the right-hand cluster
- **Build 202610170108 on the device (user report):** the Inventory button showed in the top row. The user found that position awkward and asked for it on the right side, where it's easy to press.
- **This is a deliberate change from Amethyst's default layout:**
  - Inventory (E) is now a round 69.6 pt button, directly right of Right Click and under Jump.
  - x = 0.8756154·W + 2; y = max(0.8178498·H − 69.6, Jump's bottom edge + 2); shown in game only.
  - It was removed from the top row.
  - I worked out the positions for 932×430, 956×440, 852×393 and 667×375 pt: it overlaps no other control.
- **Diagnostic line widened:** `[ZLGLFW] controls …` now lists every non-drawer control's position and hidden state.
- **Build `202610170113`** (SHA-256 `eee734b125c7e2419d9e7db9fba5f5bc7253d94502cebf39dbc5aec35d106b36`). **Not yet run on device.**
- **Device result for build 202610170113 (user report, 2026-10-17):** the user confirmed the new Inventory position on the iPhone and is happy with the control layout.

## 2026-10-17 — Camera look sensitivity matched to Amethyst
- **Checked on build 202610170113:** options.txt on the device has `mouseSensitivity:0.5` (default) and `rawMouseInput:true`.
  - Our bridge sent 1 cursor unit per point of in-game drag.
  - Amethyst's `SurfaceViewController sendTouchPoint` sends the touch location × `UIScreen.scale` while the cursor is grabbed. Its `mouse_speed` only affects the virtual mouse, and it doesn't apply `resolutionScale` while grabbed.
  - Result: look on our side was 3× slower on a @3x phone. At sensitivity 0.5, Minecraft turns 0.15° per unit, so a 100 pt swipe was 15° here versus 45° in Amethyst.
- **Change:** in-game drag deltas are now multiplied by `UIScreen.mainScreen.scale` before they are sent to GLFW. Menu pointer and virtual mouse are unchanged.
- **Build `202610170123`** (SHA-256 `a9b49e53e09ed26f15c9dec43da750b2b9de26b4b33ed99ef6d392e30b018c70`). **Not yet run on device.**
- **Device result for build 202610170123 (user report, 2026-10-17):** the camera now feels better; the previous builds were too slow.

## 2026-10-17 — Cause of the 0x8BADF00D exit reports
- **User confirmed:** the 08:00:29 and 08:00:49 sessions were closed by swiping the app away from the app switcher while Minecraft was still running.
- **This matches the report:** "Failed to terminate gracefully after 5.0s" (FRONTBOARD, process-exit watchdog). iOS gives a swiped-away app 5 s to exit; the running JVM didn't, so iOS force-killed it.
- **Impact:** not a game crash, but any world changes since the last autosave can be lost. Save and Quit (or Runtime Menu → Quit game) exits cleanly.
- **Possible improvement:** when the app goes to the background, make Minecraft pause and save, so a later swipe-away loses nothing.

## 2026-10-17 — Pause and save when leaving the app
- **Goal (user request):** swiping the app away (which force-kills it after 5 s) should no longer lose world changes since the last autosave.
- **What changed in ZLGLFW** (app lifecycle observers, installed with the on-screen window):
  - *Will resign active* (home gesture, app switcher, lock): send GLFW focus-lost. If the cursor is captured (in game, no screen open), also send ESC. Minecraft opens its pause menu, and the 1.20.1 integrated server saves the world as it pauses ("Saving and pausing game..."). The app keeps running while it's inactive, so this happens before it is suspended or killed.
  - *Did enter background:* hold a UIBackgroundTask for 8 s so the save can finish.
  - *Did become active:* send focus regained. The pause menu stays open.
- **Limitation:** if a screen is open (inventory, chat, etc.), no ESC is sent. Minecraft only pauses when no screen is open, so changes since the last autosave can still be lost then. **Assumption, not yet checked on device:** that GL rendering while inactive or briefly in the background doesn't fault.
- **Build script bug found and fixed:** `scripts/build-ipa.sh` checked `PIPESTATUS` after `| grep … || true`, so it read the status of `true`. A failed `xcodebuild` (a compile error here) still exited 0 and packaged the previous `.app` as build 202610170205; **that IPA is invalid and was overwritten.** It now records xcodebuild's own exit status and stops on failure. Before this fix, every IPA was built only after the log showed "BUILD SUCCEEDED", so no earlier build was affected.
- **Build `202610170207`** (SHA-256 `620d43ede73a4b4d630eab8a4edcfb78a487d5c4062c6fd44d04647831c0fb61`), with the new log string confirmed in the binary. **Not yet run on device.**
- **Device check to do:** in a world, swipe up to the app switcher and wait 1–2 s. jvm.log should then show "app resigning active … sent ESC" and latest.log "Saving and pausing game...". Then swipe the app away, relaunch, and confirm the world kept the latest changes.

## 2026-10-17 — Hotbar: tap or slide to select, as in Amethyst
- **User report:** tapping the hotbar doesn't change the selected item. They want to either tap or slide to a slot, as in Amethyst.
- **Old behaviour:** a slot was chosen only when the *primary* finger lifted after a short, still tap, using the touch-down point. A second finger, for example while another finger was looking around, was ignored in game. A long press on the bar broke blocks. **The exact cause of the user's failed taps wasn't established from the logs.**
- **Amethyst reference** (`input_bridge_v3.m callback_SurfaceViewController_touchHotbar`, `SurfaceViewController.m`): a separate `hotbarTouch` with a hit area of the bottom `mcscale(20)` px, `mcscale(180)` wide and centred. The slot is chosen on touch down and, with `slideable_hotbar`, again as the finger moves. A long press on a slot holds Q (drop).
- **New behaviour:**
  - In game, any finger that touches down on the hotbar becomes the hotbar touch and selects that slot immediately (light haptic). This works while another finger looks or uses the joystick.
  - Sliding along the bar selects each slot it passes, with a haptic per change.
  - Holding still for 0.35 s drops the item (Q, medium haptic).
  - The hotbar finger never looks, uses or breaks.
  - The hit area is the drawn hotbar (182×22 GUI units at Minecraft's auto GUI scale), as before.
- **Diagnostics:** each in-game touch in the bottom 15% of the screen logs its point, framebuffer, scale and computed slot. The touch summary now also counts `hotbarSelects` and `hotbarDrops`.
- **Build `202610170528`** (SHA-256 `aab291428a7c2ab061e5558e73b9cb3e62c675c81b8ef8edc2a49e7ac7b7d2e4`). It also includes pause-on-background from build 202610170207. **Not yet run on device.**

## 2026-10-17 — Device results for build 202610170528; hold-to-drop removed
- **User report:** tapping and sliding on the hotbar work, and swiping the app away mid-game (without saving first) kept the world and didn't crash.
- **Log evidence** (jvm.log, latest.log and the crash-log list, pulled from the device):
  - 20 bottom-of-screen touches in game. 19 resolved to hotbar slots, covering all of slots 0–8 (fb 1398×645, scale 1.50); 1 was outside the bar.
  - "app resigning active: focus lost, sent ESC to pause and save" was logged on each exit. latest.log shows `[05:34:55] Saving and pausing game...` right after it, and the background task started.
  - No new crash reports: the newest are still the 08:00:29 and 08:00:49 reports.
- **Change (user request):** removed hold-to-drop (Q) on the hotbar. Holding a slot now just keeps it selected, and the `hotbarDrops` counter is gone. This differs from Amethyst on purpose.
- **Build `202610170536`** (SHA-256 `a96eba546e14f84679b77bb7598c33eb3202d599898ee31d1f0d0e24100ec1a4`). **Not yet run on device.**

## 2026-10-17 — Controls tab: custom control layouts
- **User request:** a "Controls" option next to Account for adding and mapping controls, giving each a name and linking it to keyboard keys, as in Amethyst.
- **ZalithCore `Controls/ControlLayout.swift`:**
  - `ControlLayout` (buttons + joystick) and `ControlButton`, with these fields: name, up to 4 GLFW keys pressed together, a mouse button, or a special action (runtime menu, hide GUI, iOS keyboard, virtual mouse, drawer); x/y as fractions of the landscape screen; width/height in pt; toggle; show in game / show in menus / only in the More drawer.
  - `ControlLayout.amethystDefault(width:height:)` produces the same layout as the built-in overlay. The test checks it against the positions logged on the device.
  - `ControlLayoutStore` (controls/layout.json) moves a corrupt file aside, and `ControlKeys` holds the key table for the pickers.
  - Decoding tolerates missing fields.
  - 7 new tests; `swift test` passes all 63.
- **App:**
  - New **Controls** tab (between Account and Diagnostics). It lists the buttons with what each sends and where it shows; you can add, delete (swipe) and edit them, or reset to the default.
  - The per-button form: name; keyboard keys picked from a list, up to 4; mouse button; special action; toggle; visibility; size.
  - **Edit layout on screen** opens a full-screen landscape editor. Drag buttons and the joystick to move them, tap a button to edit it, and filter by In game / In menus / Drawer open.
  - Every change is saved immediately.
- **Game side:**
  - Before each launch, `MinecraftLauncher` writes the effective layout (saved or default) to controls/active.json and sets `ZALITH_CONTROLS_PATH`.
  - The ZLGLFW overlay builds its buttons and joystick from that file. If the file is missing or invalid, it falls back to its built-in Amethyst layout, which the GLFW test still uses.
  - Buttons press all of their keys together. Names wrap by word.
- **Verification:**
  - `swift test` passes (63/63).
  - `scripts/build-ipa.sh` builds 202610170549 (SHA-256 `68d57605c6e2713946239faed5c31d9e120a57869aa91df5235c7d08aa1227e1`) with no compiler warnings in the new files.
  - **Not run on device:** the editor UI, the landscape rotation request, and the game loading a custom layout are all untested.
- **Not done (compared with Amethyst):**
  - Only one layout (no named layout files or import/export).
  - No swipeable buttons, colours or per-button opacity.
  - The joystick can be moved but not resized in the editor.

## 2026-10-17 — New buttons hidden behind the editor toolbar (fixed)
- **User report (build 202610170549):** a button added in the Controls layout doesn't appear.
- **Evidence:** the controls/layout.json pulled from the device has 22 buttons. The 4 the user added ("Button" [R], "Drop item" [Q], "Drop button" [Q], "Button" [no key]) are all saved, at the same position x=0.4627, y=0.4191 (431,180 pt): the centre of the screen. The editor's floating toolbar sits there and was drawn on top of them. No active.json yet, so the game hasn't been launched with a custom layout.
- **Fix:**
  - `ControlLayout.freeSpot` places a new button at the free spot nearest the screen centre (8 pt grid), clear of every other non-drawer control, the joystick and the toolbar area (340×130 pt at W/2, 0.45 H). There is a new test.
  - The editor now draws the toolbar *underneath* the controls, so nothing can hide behind it.
  - The newly added button is outlined in the accent colour.
  - The 4 stacked buttons in the user's saved layout will now show at the centre, on top of the toolbar. Drag them apart or delete them.
- **Verification:** `swift test` passes 64/64. **Build `202610170557`** (SHA-256 `3a275de39a35ca3b002065369e6e4de0b1107afe521be1c266320b79cc4e5d87`). **Not yet run on device.**
- **Device result for build 202610170557 (user report "good to go", 2026-10-17), with log evidence:**
  - The user tidied the layout down to 19 buttons, keeping a custom "Drop button" (Q) moved to 823,53 pt.
  - jvm.log shows the game loading it: `[ZLGLFW] controls: 22 buttons from …/controls/active.json` at 13:01, and `19 buttons` at 13:26.
  - The Controls tab, the editor and custom layouts in game work on the iPhone.

## 2026-10-17 — Resolution setting, control opacity and joystick size, stale text
- **User request:** "do what you feel missing". I chose small gaps the user hits every session; larger items are proposed as separate sessions (below).
- **Render resolution setting:**
  - `LauncherSettings.renderScale` (0.25–1, default 0.5, tolerant decode) with a slider on the Account tab, which also shows the resulting framebuffer (e.g. 1398×645 px).
  - `MinecraftLauncher` now always sets `ZALITH_RENDER_SCALE` from it (it used to be fixed at 0.5) and logs it in the "Starting Minecraft" line.
  - Background: latest.log showed "Can't keep up!" warnings at 0.5. A lower scale gives a way to trade sharpness for speed. **FPS still not measured.**
- **Controls appearance:**
  - `ControlLayout.opacity` (0.2–1, default 1) and an editable joystick size (120–300 pt, resized around its centre), set in a new Appearance section on the Controls tab.
  - Both are clamped. Older layout files without these keys still load (new test).
  - The editor previews the opacity. ZLGLFW applies it as the alpha of the buttons and joystick.
- **Stale text fixed:** the Diagnostics status said the app "cannot start Minecraft", and a `LauncherModel` comment said the JVM bridge was not implemented. Both now describe the current state.
- **Verification:** `swift test` passes 65/65. **Build `202610170631`** (SHA-256 `7dbcfc528f6344cce1cec7a87d8f76b81bd3504824fcbe39702297cfe9a02ba4`), with no compiler warnings in the changed files. **Not yet run on device.**
- **Larger gaps not done here:**
  - Java 21: newer versions (1.20.5+, e.g. the installed 1.21.11) are refused.
  - Microsoft account sign-in: offline profiles only.
  - Mod loaders (Fabric/Forge): `GameFilePlanner` rejects them explicitly.
  - FPS measurement.
  - The FastSTL licence question, which blocks a public release.

## 2026-10-17 — Microsoft sign-in; runtimes for every vanilla version
**User request:** "add microsoft account sign in, then bundle all java's so all versions listed in the launcher can work".

### Microsoft sign-in (details in docs/MICROSOFT_SIGN_IN.md)
- **Flow:** the ZalithLauncher2 2.6.1 flow (`MicrosoftAuthenticator.kt`), reimplemented in `ZalithCore/Accounts/MicrosoftAuth.swift`:
  - device code at `login.microsoftonline.com/consumers`, scope `XboxLive.signin offline_access`;
  - then Xbox Live `user/authenticate` (RPS ticket `d=…`, retried without the prefix on 400);
  - then XSTS (XErr codes explained);
  - then `login_with_xbox`, `entitlements/mcstore` and `minecraft/profile`.
  - Refresh happens when the Minecraft token has less than an hour left.
- **Tests:** 5 new, with mocked HTTP. They cover pending/slow_down polling, declined codes, XSTS errors, 403 (unapproved app), no ownership, refresh, and `invalid_grant`.
- **Secrets:** `KeychainStore` holds the account JSON (tokens) in the iOS Keychain (`AfterFirstUnlockThisDeviceOnly`). Nothing token-bearing reaches settings.json or the logs; the launch log records only the name and `msa`.
- **App:**
  - `AccountModel`; the Account tab gains a Microsoft section (sign in, code with copy-and-open, cancel, sign out) and a "Play as" picker (`LauncherSettings.useMicrosoftAccount`).
  - `MinecraftLauncher.launch` is now async and resolves the identity first.
- **Client ID:** like upstream, there is none in the repo. It comes from the git-ignored `.oauth_client_id.txt` or `ZL_MS_CLIENT_ID`, and is bundled as `microsoft-client-id.txt` by the build phase. Without it, sign-in shows as unavailable.
  - Mojang must approve new Azure app IDs (<https://aka.ms/mce-reviewappid>); otherwise `login_with_xbox` answers 403. Sources are cited in the doc.
  - **Not verified against the live services or on a device.**

### Java and LWJGL for every vanilla version
I scanned all 103 releases in Mojang's manifest on 2026-10-17:

| Versions | Java | LWJGL | Extra |
|---|---|---|---|
| 1.0–1.12.2 | 8 | 2.9.x | — |
| 1.13–1.16.5 | 8 | 3.1.6–3.2.2 | — |
| 1.17–1.20.4 | 16/17 | 3.2.2–3.3.2 | — |
| 1.20.5–1.21.11 | 21 | 3.3.3 | lwjgl-freetype |
| 26.1–26.2 | 25 | 3.4.1 | freetype (+vulkan in 26.2) |
| 26.3 | 25 | 3.4.3 | **lwjgl-sdl** + vulkan, shaderc, spvc, vma |

Changes:
- **Runtimes:** `fetch-runtime.sh` now fetches AngelAuraMC's iOS JREs 8 (1.8.0_472), 17, 21 (21.0.8) and 25 (25.0.4), with SHA-256 pinned (trust on first use).
  - Each libjvm is iOS platform 2 and contains the same iOS 26 JIT hooks as the working Java 17: `DeviceHasTXM`, `MirrorMappedCodeCache`, `brk #0x69`.
  - The build phase bundles every `build/runtime/jre*`.
- **Runtime choice:** `GameRuntime` (ZalithCore, 4 new tests) picks the smallest bundled Java ≥ the version's `javaVersion` (default 8). It also works out the LWJGL version from the libraries and maps it to the 3.3.3 or 3.4.1 build, the same rule as upstream's `lwjglVersionDir`.
- **JVM options:** `-XX:+IgnoreUnrecognizedVMOptions` was added so one option list serves Java 8–25.
- **lwjglx** (LWJGL 2 API) is built from the 3.3.3 fork and added last on the classpath for LWJGL 2 versions, as upstream does.
- **FreeType:** VER-2-13-3 built for iOS (`scripts/build-freetype.sh`). `lwjgl-freetype` (3.3.3 and 3.4.1) is added for versions that list it.
- **LWJGL 3.4.1** comes from the fork's `wip/rebase_3.4.1` (`702c2102a287`) via `LWJGL_SERIES=3.4.1 scripts/build-lwjgl.sh`. It needed:
  - libffi 3.5.2 (3.4.1 calls `ffi_get_version`/`ffi_get_closure_size`; SHA-256 matches GitHub's published asset digest);
  - `ant init`;
  - `-Djdk25=true`;
  - removing the fork's release check for `JAVA8_HOME`. That check only matters for Java 8 compatibility of official releases; these jars run only on Java 25.
- **GLFW bridge:** `glfwGetWindowTitle` was added, the one function LWJGL 3.4.1 requires that the bridge lacked. All 118 required functions are now exported.
- **compat stubs:** `zalith-ios-compat.jar` is now `--release 8`, so Java 8 can load it.
- **26.3+ is refused** with a clear message: it uses SDL3 and Vulkan instead of GLFW and OpenGL, which this launcher's window and graphics layers don't provide.

### Verification
- `swift test` passes 74/74.
- **Build `202610170703`** (SHA-256 `80d5a6224871dea7833fcf1021170d4776f4e9e05a110c216828b192c24fef0d`): IPA 183 MB, app 488 MB, with no compiler warnings in the changed files.
- **Device status: only Java 17 / 1.20.1 has run so far.** Java 8, 21 and 25, lwjglx, FreeType and LWJGL 3.4.1 are bundled but untested.
- Versions to try first: 1.21.11 (installed: Java 21 + FreeType), 1.16.5 (Java 8), 1.12.2 (Java 8 + lwjglx) and 26.1 (Java 25 + LWJGL 3.4.1).

## 2026-10-17 — Minecraft 1.21.11 on Java 21: first run on device
- **Build 202610170703, launched from StikDebug.** Evidence: launcher.log, jvm.log and latest.log pulled from the device; latest.log saved as `docs/evidence/2026-10-17-minecraft-1.21.11-java21-latest.log`.
- **Launch line:** "Starting Minecraft 1.21.11 as Player (legacy): Java 21 (asks 21), LWJGL 3.3.3 for 3.3.3, heap 1337 MB, render scale 100%, 54 classpath entries".
  - The JIT26 handshake worked on Java 21 (probe `0x…690000e0`, extension sent).
  - GL 3.3 context; framebuffer 1290×2796 at the user's 100% scale.
  - The custom 19-button layout loaded.
- **Game:** backend LWJGL 3.3.3 (our build), OpenAL initialised, the sound engine started, atlases and fonts loaded (unifont), 1470 recipes.
  - "Player joined the game" at 07:09:14.
  - "Saving and pausing game..." at 07:09:22, when the app left the foreground.
  - All dimensions saved, then "Stopping!" at 07:09:58.
  - No hs_err file, no crash report, no new iOS crash log.
- **Errors in latest.log, all expected:**
  - "Error while loading the narrator": no text-to-speech library.
  - Realms and user-properties fetches fail on the offline account.
  - One `random_sequences` saved-data parse error: the world was last saved by an older version.
- **Result:** Java 21 + FreeType-era versions run on the iPhone. Java 8 (1.13–1.16.5), lwjglx (≤1.12.2) and Java 25 + LWJGL 3.4.1 (26.1–26.2) are still untested on device.

## 2026-10-17 — Game files for 1.16.5 / 1.12.2 / 26.1 pushed; Microsoft sign-in via Live web flow
- **Game files:**
  - `zalith-cli install` on the Mac, every file hash-checked: 1.16.5 (2625 files), 1.12.2 (1322) and 26.1 (4797), all with 0 failures. build/gamedata is now 1.3 GB.
  - `scripts/push-gamedata.sh` exited 0. It **merges** into the device's game folder: before and after the push, the device listed versions 1.12.2, 1.13.2, 1.16.5, 1.19.1, 1.20.1, 1.21.11, 26.1 and 26.3, and the user's saves and options.txt were still there.
  - The 26.1 version JSON passes `--sun-misc-unsafe-memory-access=allow --enable-native-access=ALL-UNNAMED`, which HotSpot accepts as JNI options in the `=` form (as 1.21.11's did).
- **Microsoft sign-in, user decision:** sign in the way Amethyst-iOS does, using login.live.com and Microsoft's Minecraft launcher client ID `00000000402b5328`, instead of waiting for Mojang to approve an Azure ID.
  - Implemented as `MicrosoftAuth.live` and `liveAuthorizeURL`/`liveCode(from:)`/`redeemLiveCode`, plus refresh on the Live endpoint and a bare RPS ticket. 1 new test; 75/75 pass.
  - `AccountModel` uses `ASWebAuthenticationSession` (ephemeral) and keeps the device-code flow for builds that bundle their own ID.
  - Accounts record which client ID signed in, so a refresh uses the same one.
  - The trade-off is noted in docs/MICROSOFT_SIGN_IN.md: the ID isn't ours and Microsoft could block it.
  - **Build `202610170717`** (SHA-256 `e63d989e9ca3479d7ae0ba021d29099e93fdd99700649b44cbf37cca27606b89`). **Not yet run on device.**

## 2026-10-17 — Device run of Java 8 / 25 builds: two bugs found and fixed
- **Evidence:** launcher.log, jvm.log, latest.log and `logs/hs_err_pid6871.log` pulled from the device. Builds 202610170703 (until 07:21) and 202610170717 (from 07:21:44).
- **What actually ran:**
  - launcher.log shows launches of 1.13.2 (07:10:58), 26.1 (×4, one refused as "JIT is not enabled") and 1.21.11 (07:17:53). Both 26.3 attempts were refused as designed.
  - **There is no launch of 1.16.5 or 1.12.2** in the log.
  - **No Microsoft sign-in events.** On 0703 the button was disabled (no client ID), and 0717 only ran from 07:21:44. Logging is now added.
- **Java 8 (1.13.2):** the JVM died about 2 s in, right after "Setting user", with `Out of Memory Error (allocation.cpp:389)`.
  - Cause: C2 (`ConcurrentHashMap::putVal`, 362 bytes) was in `CodeSection::expand_locs` ← `MacroAssembler::read_polling_page` ← `MachEpilogNode::emit` ← `Compile::scratch_emit_size`, and requested a 134,217,776-byte arena chunk.
  - The heap held only about 110 MB and the device showed 432 MB free. So this is a runaway in this iOS JDK 8 build's C2, not the game using up memory.
  - **Workaround:** `-XX:TieredStopAtLevel=1` (C1 only) on Java 8. Not yet verified.
- **Java 25 (26.1):** `UnsupportedClassVersionError: org/lwjgl/system/MemoryUtil … class file version 70.0`.
  - Cause: LWJGL 3.4.1 compiles its `META-INF/versions/25` classes with `--release ${jdk.version} --enable-preview`, and `jdk.version` is the build JDK (26 here).
  - **Fix in `build-lwjgl.sh`:** patch that to `--release 25` (the classes use no preview features: they were 70.0, not 70.65535), and drop the generated `versions/25/module-info.class`, which the module-info tool stamps with the build JDK's version and which is unused on the classpath.
  - All 5390 classes in the 3.4.1 jars are now version ≤ 69; the bundled `MemoryUtil` (versions/25) is 69.
- **Sign-in logging:** `AccountModel` now logs start, the code returned, cancel, and a failure to open the page (never tokens).
- **Build `202610170727`** (SHA-256 `46c89ffc910f37a14a6e9775a23dac87b3de3a6cd3902f6c0b21d3b59f1bdf2f`). **Not yet run on device.**

## 2026-10-17 — Java 8 and Java 25 failures on device; Microsoft sign-in works
- **Evidence:** launcher.log, jvm.log, Minecraft crash reports (07.28.01, 07.33.03), `hs_err_pid7039.log` and iOS crash `ZalithIOS-2026-10-17-143504.ips` (build 202610170727), all pulled from the device.
- **Microsoft sign-in works on the device (Live web flow):** every launch from 07:27:19 ran "as <the user's profile> (msa)", meaning a real Minecraft profile and token from the Keychain. The user reported no problem with the sign-in.
- **Java 8 (1.13.2, 1.16.5, 1.12.2):**
  - All fail early with `NoSuchMethodError: java.nio.ByteBuffer.position(I)Ljava/nio/ByteBuffer;` in `org.lwjgl.system.MemoryUtil.<clinit>`. (The earlier C2 OOM was a separate problem, and C1-only is still applied on Java 8.)
  - Cause: LWJGL was compiled with `-source 8 -target 8` against JDK 26's class library, so the calls link to the Java 9+ covariant overrides. Official LWJGL builds compile against a JDK 8 `rt.jar` (`JAVA8_HOME`, `--boot-class-path`).
  - `--release 8` is no substitute because it hides `sun.misc.Unsafe` (I tested this).
  - **Fix:** `build-lwjgl.sh` points `JAVA8_HOME` at a directory linking the bundled iOS JRE 8's `rt.jar` (the same OpenJDK 8 class library). For 3.3.3, which builds in "JDK 8 mode" on JDK 26 and so never applied the boot class path, the boot class path is now applied whenever `JAVA8_HOME` is set.
  - Verified with javap: `MemoryUtil` now calls `ByteBuffer.position:(I)Ljava/nio/Buffer;`, in both 3.3.3 and 3.4.1.
- **Java 25 (26.1):**
  - SIGBUS in `CodeBlob::CodeBlob` ← `UpcallStub::create` ← `jdk.internal.foreign.abi.UpcallLinker` ← `org.lwjgl.system.Upcalls.upcallCreate` ← `GLFWErrorCallback.create`. LWJGL 3.4.1's Java 25 classes (`META-INF/versions/25`) create callbacks with the FFM API, and this iOS JDK 25 writes upcall stubs straight into the JIT-protected code cache.
  - **Fix:** the 3.4.1 jars ship without `META-INF/versions/25`, so LWJGL uses its libffi/Unsafe implementation, the same one 3.3.3 uses successfully on Java 17/21. Minecraft passes `--sun-misc-unsafe-memory-access=allow` for this.
  - The earlier "--release 25" and "drop the JAVA8_HOME check" patches are gone: `JAVA8_HOME` is now real, and the script resets the fork's build files before each build.
- **Scope (user, 2026-10-17):** versions up to 1.12.2 and alpha/beta are "probably not needed". The target is 1.13 – 26.2. lwjglx stays bundled, but is no longer pursued.
- **Build `202610170739`** (SHA-256 `15fabddde22f19822dcfca308e36d2c7b68e582f5f4e35cb309a8f51352f75c7`). **Not yet run on device.**

## 2026-10-17 — 26.1 and 1.16.5 get further; GLFW IME functions and gl4es added
- **Evidence:** Minecraft crash reports 07.48.42 (26.1) and 07.49.06 (1.16.5), build 202610170739. No hs_err and no iOS crash log, so the earlier JVM-level failures are gone.
- **26.1:** `NullPointerException` in `Checks.check` ← `GLFW.nglfwSetPreeditCallback` ← `InputConstants.setupKeyboardCallbacks`.
  - LWJGL 3.4.1 binds 7 IME functions as optional: `glfwSetPreeditCallback`, `glfwSetIMEStatusCallback`, `glfwSetPreeditCandidateCallback`, `glfwResetPreeditText`, `glfw{Get,Set}PreeditCursorRectangle`, `glfwGetPreeditCandidate`. The bridge had none of them.
  - **Fix:** ZLGLFW now provides them as no-ops: callbacks are stored and returned but never called, since iOS text goes through ZLKeyboardProxy. The bridge now exports every required (118) and optional (7) GLFW function LWJGL 3.4.1 binds.
- **1.16.5:** got past start-up (the Java 8 LWJGL fix works) and failed while rendering a screen. `NullPointerException` in `Checks.check` ← `GL11.glFogfv` ← `RenderSystem.fog`: MobileGlues does not implement fixed-function GL, which 1.13–1.16.5 use.
  - **gl4es added**, as Amethyst/ZalithLauncher use for these versions. `scripts/build-gl4es.sh` builds PojavLauncherTeam/gl4es `mergewithios` `c3d6a54f8a2c` (MIT) for iOS: NOX11 + NOEGL, ES2 backend, CMake policy minimum 3.5.
  - Our patch `patches/gl4es/0001-ios-use-app-angle.patch` makes four changes:
    - (a) On Apple, resolve GLES from the `LIBGL_GLES` library (ANGLE's libGLESv2, loaded before gl4es, which upstream's `RTLD_NEXT`-only lookup cannot see).
    - (b) Don't link the branch's prebuilt MetalANGLE.framework.
    - (c) Add `src/gl/zalith_ios.c`, exporting `OSMesaGetProcAddress` → `gl4es_GetProcAddress`. Mach-O has no symbol aliases, so gl4es exports no plain `gl*` names on Apple. LWJGL's `GL` on "macOS" resolves every function through `OSMesaGetProcAddress` when the library has it.
    - (d) Define `glGenBuffers`/`glStencilFunc`/`glStencilOp`, which gl4es calls internally by their public names.
  - **Result:** `libgl4es.dylib` is iOS platform 2 with no undefined `gl*` imports, and is bundled in Frameworks.
- **Launcher:** Java 8 versions (1.13–1.16.5) now use gl4es (`org.lwjgl.opengl.libname`, plus `LIBGL_GLES` = ANGLE's libGLESv2 and `LIBGL_ES=2`); 1.17+ keep MobileGlues.
  - ZLGLFW's `glfwGetProcAddress` now resolves from the active GL library (`ZALITH_GL_LIBRARY`, via `OSMesaGetProcAddress` when present) instead of always MobileGlues.
- **Build `202610170757`** (SHA-256 `c219357d8a8afd4edb53382ad3a9fbe2a561b1195b3a55be07450c6ea1748f14`). **Not yet run on device.**

## 2026-10-17 — Build 202610170757 on device: two GL-layer bugs found and fixed
- **Evidence:** crash reports 08.07.08 and 08.08.34 (26.1) and 08.41.06 (1.21.11); `hs_err_pid7239/7259.log` (1.16.5); jvm.log.
- **26.1 (MobileGlues):** start-up now completes up to `MainTarget.allocateDepthAttachment`, then `IllegalStateException: OpenGL error 1282` in `GlDevice.createTexture`.
  - javap of the unobfuscated 26.1 jar: DEPTH32 = internal `GL_DEPTH_COMPONENT32`, `GL_DEPTH_COMPONENT`, `GL_FLOAT`, which is invalid in ES 3.
  - But MobileGlues converts that format, and its `glGetError` always returns `GL_NO_ERROR`. So the error had to come from raw ANGLE.
  - **Cause:** LWJGL 3.4.1's `GL` function provider tries `eglGetProcAddress` from the GL library before `OSMesaGetProcAddress`. `dlsym()` on libmobileglues also searches its dependencies and returns **ANGLE's** `eglGetProcAddress`, so 26.1 was calling raw GLES and bypassing MobileGlues. LWJGL 3.3.3 has no such step, which is why 1.20.1/1.21.11 work.
  - **Fix:** `patches/lwjgl/3.4.1-0001-macos-no-egl-getprocaddress.patch` skips that lookup on MACOSX. `build-lwjgl.sh` now applies `patches/lwjgl/<series>-*.patch`, and javap confirms the check in `GL$1`.
- **1.16.5 (gl4es):** SIGSEGV in `gl4es_glGetError` from `GL.createCapabilities`.
  - gl4es on Apple defines `NO_INIT_CONSTRUCTOR` (init.c) and skips `load_libs()`, so nothing had initialised it and `glstate` was NULL.
  - **Fix:** on the first on-screen `glfwMakeContextCurrent` with `ZALITH_GL_LIBRARY` = gl4es, ZLGLFW dlopens gl4es and calls `set_getprocaddress` (→ ANGLE's `eglGetProcAddress`), then `initialize_gl4es()`. LWJGL's later dlopen of the same path reuses it.
- **1.21.11 (open):** about a minute into play, "Can't map buffer, opengl error 0" (`mapBuffer`): a buffer mapping returned NULL through MobileGlues/ANGLE. Not yet investigated; 1.21.11 had earlier played for over a minute without it.
- **Build `202610171119`** (SHA-256 `fea8d1166a91c6303377aadf34546273fe5a6e6954f8ce885e7136a064064a90`). **Not yet run on device.**
- **Device result for build 202610171119 (user report, 2026-10-17):** Minecraft 26.1 (Java 25, LWJGL 3.4.1, MobileGlues) and 1.16.5 (Java 8, LWJGL 3.3.3, gl4es) both start and run, and 1.21.11 "worked seamlessly". The user played them on the iPhone with their Microsoft account.

## 2026-10-17 — FastSTL removed (licence blocker for public release)
- **User intent:** publish the launcher (video, public download) as an alternative to PojavLauncher.
- **Blocker:** FastSTL (MobileGL-Dev/FastSTL, header-only `UnorderedMap.h`, compiled into libmobileglues) has no licence. Its README only says it is "used to store the code of FastSTL for use in MobileGL and MobileGlues projects". The shipped libmobileglues.dylib contained 18 `FastSTL::` symbols.
- **Fix:**
  - `patches/mobileglues/0002-use-std-unordered-map-instead-of-faststl.patch`: MobileGlues uses FastSTL in exactly one place, the `UnorderedMap` alias in `includes.h` (13 uses: per-shader/program flags, the GLSL cache index, the default fragment shader map). The alias now maps to `std::unordered_map` with the same template parameters.
  - `build-mobileglues.sh` no longer fetches FastSTL, deletes any old copy, and fails if `nm -C` finds `FastSTL::` in the built library.
- **Result:** the rebuilt libmobileglues.dylib (iOS platform 2) has 0 FastSTL symbols, and the unpacked IPA has no file mentioning FastSTL.
- **Expected cost:** a few tens of ns more per map lookup, at most a couple per draw call. Estimated well under 1 ms per frame; not measured.
- **Build `202610171151`** (SHA-256 `1d510016accc9bc96fc62950d722569ecb800033f5322ff9c6a74b3cdbd56859`). **Needs a device check:** 1.21.11 and 26.1, which use MobileGlues.

## 2026-10-17 — FastSTL-free build checked on device; 26.2 Cocoa stub
- **Build 202610171151** (no FastSTL), from the device logs:
  - 26.1 (11:57:52) and 1.21.11 (11:58:44) each loaded fully three times (sound engine and atlases rebuilt on each resource reload) and quit with "Stopping!".
  - No GL errors, crash reports, hs_err files or iOS crash logs.
  - Neither log shows joining a world. Afterwards the user reported that 1.21.11 and 26.1 both **played fine in a world** on this build, so removing FastSTL caused no visible regression.
- **Earlier runs that day (build 202610171119):**
  - 1.16.5 (11:25) and 1.15.2 (11:31) on gl4es: "gl4es initialised …" logged, then a clean quit.
  - 26.1.2 finished loading before the app was sent to the background.
  - The 1.16.5 `gl4es_glGetError` crash at 11:15 was on build 202610170757, before the gl4es init fix.
- **26.2:** crash report "A required function is missing: glfwGetCocoaView" from `GLFWNativeCocoa.<clinit>`, reached via `MacosUtil.setWindowColorSpaceForOpenGLBecauseGLFWDoesnt`.
  - 26.2's MacosUtil (javap of the verified 26.2 client jar, SHA-1 2dc72797) skips the NSWindow calls when `glfwGetCocoaWindow` returns 0, which our stub does.
  - **Fix:** a `glfwGetCocoaView` stub returning NULL. All Cocoa, NSGL and EGL native-access functions LWJGL 3.3.3/3.4.1 require are now exported. The only ones still missing are Win32/X11/Wayland/GLX/OSMesa, which are never loaded on "Mac OS X".
- **Build `202610171201`** (SHA-256 `e9fbe1e43d59eeae5c7b5da00b0925b47afb7e9f474d8ece50e5a7805a95a57e`). **Not yet run on device.**
- **26.2 on build 202610171201 (user report + jvm.log):** past the Cocoa stub, but the game ran behind the launcher: sound playing, launcher stuck on "Minecraft is running". jvm.log: `[ZLGLFW] window "Minecraft 26.2" offscreen: 854x480 pt`.
  - Cause: 26.2's `Window.createGlfwWindow` sets `GLFW_VISIBLE` (0x20004) to 0 before `glfwCreateWindow`, and `Minecraft.<init>` calls `glfwShowWindow` later (javap). ZLGLFW made any window created invisible an offscreen pbuffer, and `glfwShowWindow` ignores offscreen windows.
  - **Fix:** the first window is always the on-screen game window, shown at once whatever the hint; only further windows are offscreen. **Build `202610171212`** (SHA-256 `cf952150bc67c99d2e2f36e105362065a838468b1e56cc6c1486f9ac56a90188`). **Not yet run on device.**
- **26.2 renders the red loading screen without the logo, then black; the game keeps running (sound).**
  - With `glDebugVerbosity:4` in options.txt (temporary; the original is saved and will be restored), no GL debug messages appeared, and "Using graphics device extensions:" was empty.
  - 26.1 printed `GL_KHR_debug, GL_EXT_texture_filter_anisotropic` there. javap: 26.2's `GlDevice` builds that list from its own `GL.createCapabilities()` flags (anisotropic, ARB clip_control/shader_draw_parameters/draw_indirect/multi_draw_indirect/base_instance; KHR_debug in GlDebugLabel). So in 26.2 **every extension flag was false**, KHR_debug included, which is also why there was no debug output.
  - The GL calls 26.2 makes match 26.1's apart from LWJGL class renames and those optional ARB paths. MobileGlues logs no shader compile or link failures.
  - **Next:** a diagnostic launcher switch. If `logs/lwjgl-debug` exists, the launcher adds `-Dorg.lwjgl.util.Debug/DebugFunctions/DebugLoader=true`, so LWJGL logs missing GL entry points and rejected extensions. **Build `202610171223`** (SHA-256 `79dd4ad1375a4a631d6e3c8c39521efe408dd4ec11ab79480192e39f240e2a06`); the flag file is pushed to the device.
- **LWJGL debug run (build 202610171223):** LWJGL reported no missing GL entry points and no rejected extensions, so the empty extension list is not the fault. 26.1's latest run printed an empty "optional rendering extensions" list too, and renders fine.
  - **Real difference, from jvm.log ordering:** in 26.2, "Initializing MobileGlues … EGL initialized" (line 97) comes **before** ZLGLFW's "initialised: ANGLE Metal display" (400) and the window (404). In 26.1 it is window (138), then MobileGlues (140). 26.2 loads the GL library early (it newly calls `GL.getFunctionProvider`), and MobileGlues initialises in a static constructor (init.cpp). So it created its default EGL display and queried GLES before the app's ANGLE display and context existed.
  - **Fix:** `patches/mobileglues/0003-apple-lazy-init-on-first-gl-call.patch`. On Apple there is no load-time init; `mg_ensure_init()` (an atomic, re-entrant one-time guard) runs `proc_init()` on the first `glGetIntegerv`/`glGetString`/`glGetStringi`/`glGetError`, which LWJGL's `createCapabilities` calls with the game context current. That is 26.1's working order for every version.
  - **Build `202610171231`** (SHA-256 `61b2c94f1b9a250ddb937863906647904ed66b6a7b8048caac5613c765faf527`). Needs device checks on 26.2 **and** 1.21.11, because this changes MobileGlues init for every version from 1.17 up.
- **Build 202610171231 (lazy MobileGlues init) on device:** 26.2 unchanged (red, then black); 1.21.11 fine. Lazy init is kept: it is safe and matches 26.1's order.
  - **Real cause, from comparing GL function names (class renames ignored):** 26.2 newly calls `glMultiDrawArrays` (and `glMultiDrawElementsBaseVertex`, `glColorMaski`, `glClearBufferfv`, …), while 26.1 drew with `glDrawElementsBaseVertex`/`glDrawArrays`.
  - In MobileGlues f0fb4d3, `glMultiDrawArrays` is an **active stub** (`gl_stub.cpp`: logs "Stub function", draws nothing). Everything 26.2 draws through it, such as the logo and the GUI, never appears; only the clear colour shows.
  - The other active stubs 26.2 can reach are behind ARB flags that are false here (clip control, base instance, indirect), or are non-essential (`glLogicOp`, `glPolygonMode`, `glQueryCounter`).
  - **Fix:** `patches/mobileglues/0004-implement-glmultidrawarrays.patch` removes the stub and adds an `extern "C"` `glMultiDrawArrays` in multidraw.cpp that issues one `glDrawArrays` per draw (a passthrough, the same as the caller making the calls). The first attempt exported a C++-mangled name, which `build-mobileglues.sh` now catches: it fails if `_glMultiDrawArrays` isn't exported.
  - **Build `202610171244`** (SHA-256 `fef7df3796db4caa2ed6db8a1c9f6fa4e27e1638ddd465dcb408bd0649288867`). **Not yet run on device.**
- **Build 202610171244 (glMultiDrawArrays) on device:** 26.2 still black; 1.21.11 fine. MobileGlues prints no warnings in release builds.
  - **Next suspect, from the same diff:** 26.2's `GlStateManager._colorMask` now always calls `glColorMaski` (26.1 used `glColorMask`). MobileGlues forwards it unchanged to ANGLE, but per-buffer masks are core only from ES 3.2, and ANGLE Metal provides ES 3.0 (MobileGlues logs "OpenGL ES 3.0 (300)"). Every call is rejected, so once colour writes were masked off they never came back on: red first frames, then black.
  - **Fix:** `patches/mobileglues/0005-colormaski-es30-fallback.patch`. Below ES 3.2, `glColorMaski(0, …)` applies `glColorMask`; other buffers are ignored, since ES 3.0 has no per-buffer masks. The build script checks that `_glColorMaski` and `_glMultiDrawArrays` are exported.
  - **Build `202610171253`** (SHA-256 `561506fda171851def63321b7bd91e9e27c91d4a651079948e8fb3c846a3dbd4`). **Not yet run on device.**
- **Build 202610171253 (glColorMaski fallback) on device:** 26.2 still black. The user confirmed 1.21.11 was never affected; only 26.2 is broken.
  - **Switching from guessing to evidence:** MobileGlues' release build hides every GLES error (`glGetError` always returns `GL_NO_ERROR`, and `CHECK_GL_ERROR` is empty unless `GLOBAL_DEBUG`, which also logs every call).
  - `patches/mobileglues/0006-optional-gl-error-reporting.patch` adds an error-only mode: with `-DZALITH_CHECK_GL_ERRORS`, each checked call (native passthroughs included) prints `[MG-GLERR] <error> in <function> (<file>:<line>)` to stderr (jvm.log), capped at the first 400, then every 1000th.
  - It is compiled in only with `ZALITH_MG_CHECK_ERRORS=1 scripts/build-mobileglues.sh`; release builds are unaffected.
  - **Diagnostic build `202610171302`** (SHA-256 `7ba5b70eed392864d2c17e21a61324a0d4c77a7bbdcd7b7fe676fbbb3401baa6`, copy at `build/ipa/diag/`). Not a release build: rebuild MobileGlues without the flag before committing or publishing.
- **Diagnostic build 202610171302 on device (26.2):** 1245 `[MG-GLERR]` lines, almost all `GL_INVALID_OPERATION`:
  - `glUseProgram` (program.cpp:199) ×412 and `glUniform1i` ×410: the programs 26.2 uses are **not linked** in ANGLE, so nothing can draw and only the clear colour shows.
  - Also `glFenceSync` ×261, `glClientWaitSync` ×145, `glDeleteBuffers` ×15. These are probably errors left over from the failing draws and reported at the next checked call.
  - No "linking failed" message appeared, so MobileGlues never saw 26.2 query the link status, and the release build does not print shader logs.
  - **Patch 0007 (diagnostic only):** after each `glLinkProgram`, a failed link prints `[MG-LINK]` with the link log and, for each attached shader that failed to compile, its compile log and the start of the translated ES source. GLSL→ESSL conversion failures are printed too. **Diagnostic build `202610171313`** (SHA-256 `9af4277cda2d176fb692abbf49fdf85019f3385374cfde2f0cae916adee4de39`).

## 2026-10-17 — 26.2 paused (user decision); release build restored
- **User decision:** 26.2 "isn't a big concern right now and took too much time": skip it for now.
- **Where the 26.2 investigation stands, for whoever picks it up:**
  - 26.2 starts and runs (sound, input), but draws only the clear colour.
  - The diagnostic build showed `GL_INVALID_OPERATION` from `glUseProgram`/`glUniform1i`: the shader programs are **not linked** in ANGLE (ES 3.0) after MobileGlues' GLSL→ESSL translation.
  - Patch 0007 prints the link and compile logs plus the translated source (`ZALITH_MG_CHECK_ERRORS=1 scripts/build-mobileglues.sh`), but that run was not made. The next step is that run, then fixing the translation or shader feature that fails.
  - Ruled out along the way: the hidden window (fixed), the Cocoa stub (fixed), extension flags, LWJGL entry points, MobileGlues init order (lazy init kept), the `glMultiDrawArrays` stub (fixed), and the `glColorMaski` ES 3.0 rejection (fixed).
- **Launcher:** versions that list `lwjgl-vulkan` (26.2; 26.1.x does not) are now refused with a clear message, like 26.3+ (SDL). The supported range is **1.13 – 26.1.2**.
- **Kept MobileGlues patches:**
  - 0002: no FastSTL.
  - 0003: lazy init on Apple.
  - 0004: `glMultiDrawArrays`.
  - 0005: `glColorMaski` fallback below ES 3.2.
  - 0006/0007: diagnostics, inert unless built with the flag.
  - 1.21.11 was fine on every one of these builds (user).
- **Phone restored:**
  - `logs/lwjgl-debug` now says `off`; the launcher only enables LWJGL debug when it says `on`, since devicectl cannot delete files.
  - `glDebugVerbosity` is back to 1 in the *current* options.txt, keeping the user's later settings.
- **Release build `202610171320`** (SHA-256 `01060a5cddecfc27e4d17721ad25c44946e661d07273bca7f6540f3cf49e04b1`):
  - checked: MobileGlues without diagnostic strings, 0 FastSTL symbols, no bundled client ID;
  - `swift test` passes 75/75;
  - not yet run on device.
