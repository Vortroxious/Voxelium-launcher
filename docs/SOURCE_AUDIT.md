# Source Audit: ZalithLauncher2 2.6.1

## Identification (verified)
- Repository: https://github.com/ZalithLauncher/ZalithLauncher2
- Tag `2.6.1` → commit `ed872ebf53ef21800584ac435aa900c3220750c7` (`git ls-remote --tags`). A newer tag `2.7` exists.
- `ZalithLauncher/gradle.properties`: `launcher_version_name=2.6.1`, `launcher_version_code=200043`.
- Application ID / namespace: `com.movtery.zalithlauncher`.
- Commit date: 2026-09-28. Audited from a shallow clone of the tag (`git clone --depth 1 --branch 2.6.1`).
- License: GPL-3.0 (`LICENSE`). The README adds GPLv3 §7 terms: (b) keep copyright notices, (c) modified versions must use a reasonably different name or version.

## Modules (`settings.gradle.kts`)
| Module | Role | iOS relevance |
|---|---|---|
| `ZalithLauncher` | Main Android app (Kotlin, Jetpack Compose, Room, Hilt) | UI and Android APIs are not portable. The launch logic serves as a reference only |
| `LWJGL` (`3.3.3`, `3.4.1`, `shared`, `patches`) | Fork of LWJGL Java classes: custom `org.lwjgl.glfw.GLFW` and `CallbackBridge`, `PojavRendererInit`, a JSound → OpenAL bridge | The approach transfers (replace GLFW with a bridge to the host). Natives come from prebuilt Android AARs |
| `LayerController`, `ColorPicker`, `CardGrid`, `Guide` | Compose UI components | Not portable |
| `InputMap` | Controller/keyboard mapping | Concepts reusable |
| `Terracotta` | Multiplayer tunnelling; ships prebuilt Android `libterracotta.so` | Not portable as shipped |

## Launch path (reference: `game/launch/*.kt`, 2531 lines)
- `LaunchArgs.kt` builds the JVM and game arguments and classpath. Parts are marked "Modified from PojavLauncher".
- `GameManifest.Rule.checkRules()` is **not** the vanilla rule algorithm. It returns false if any rule is an `allow` for `os.name == "osx"`, and true otherwise. In effect it treats the device as non-macOS.
- `filterLibrary()` drops every `org.lwjgl*`, `jinput-platform` and `twitch-platform` library. These are replaced by the launcher's bundled LWJGL.
- `detectLwjglVersion()` / `lwjglVersionDir()` choose bundled LWJGL 3.3.3 or 3.4.1.
- The JVM is started in-process through JNI (`jni/jre_launcher.c`, `JvmLauncher.kt`). Android linker-namespace hooks are used (`jni/linkerhook`, `driver_helper/nsbypass.c`).

## Native and runtime assets
- Bundled JREs: `assets/runtimes/jre-{8,17,21,25}/bin-{arm,arm64,x86,x86_64}.tar.xz` + `universal.tar.xz`. These are **Android/Linux bionic builds and cannot run on iOS**.
- Prebuilt AARs in `ZalithLauncher/libs/`: NG-GL4ES, SDL, kopper-zink, lwjgl-3.3.3/3.4.1 natives, openal-soft, spirv-cross.
- Renderers (`game/renderer/renderers`): GL4ES, NG-GL4ES, VirGL, Freedreno, Panfrost, Kopper-Zink. All of them target Android EGL / Mesa drivers.
- `jni/ctxbridges`: EGL, OSMesa and virgl context bridges. iOS has no EGL, so none of these are usable there.

## Authentication
`game/account/`: Microsoft, offline, Yggdrasil (third-party auth servers), and a wardrobe/skin module. The Microsoft flow is standard OAuth → Xbox Live → XSTS → Minecraft services. It could be reimplemented on iOS with `ASWebAuthenticationSession`. **This project does not implement it yet.**

## iOS prior art (verified metadata, code not audited line by line)
- `PojavLauncherTeam/PojavLauncher_iOS`: GPL-3.0, **archived**. Its README names the successor.
- `AngelAuraMC/Amethyst-iOS`: GPL-3.0, active (last pushed 2026-10-04). It does the following:
  - downloads prebuilt iOS OpenJDK builds from `https://assets.angelauramc.dev/openjdk/ios-arm64/jre{8,17,21,25}-ios-aarch64.zip`. All four returned HTTP 200, 22–28 MB each.
  - uses the MobileGlues submodule (GL over a translation layer) and fishhook.
  - ships entitlements for sideload, TrollStore and codesign. The sideload set includes `get-task-allow`, `extended-virtual-addressing` and `increased-memory-limit`.
  - its README states JIT is required, StikDebug/SideStore/AltStore need Wi-Fi or a computer, and distribution-certificate signing services are unsupported.
- `StikDebug/StikDebug`: AGPL-3.0, "on-device debugger/JIT enabler for iOS versions 17.4+". `StikDebug/StikJIT`: MPL-2.0 XCFramework.

## Provenance policy for this repo
No ZalithLauncher2 or Amethyst source has been copied. `ZalithCore` is a fresh Swift implementation of the public Mojang file formats. Where behaviour intentionally mirrors upstream (the LWJGL filter, non-osx rule evaluation), the code comments cite the upstream file.
