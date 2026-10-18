# Voxelium

An experimental iOS launcher for Minecraft: Java Edition, inspired by [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) 2.6.1.

> **Experimental.** Voxelium runs Minecraft: Java Edition **1.13 – 26.1.2** on an iPhone (tested on an iPhone 15 Pro Max / iOS 27): Java 8/17/21/25 in-process, OpenGL via MobileGlues or gl4es on ANGLE (Metal), with on-screen touch controls, custom layouts, haptics, sound and Microsoft sign-in. It needs JIT through StikDebug and is sideloaded (no App Store build). Performance is unmeasured; 26.2+ and 1.12.2 and older are not supported yet. See [docs/FINAL_BUILD_REPORT.md](docs/FINAL_BUILD_REPORT.md).

## Feature status
| Feature | Status | Evidence |
|---|---|---|
| Version manifest / version JSON / asset index parsing | ✅ Unit tested (macOS) | `swift test`, real Mojang fixtures |
| Library rule evaluation, LWJGL filtering, classpath planning | ✅ Unit tested (macOS) | Counts cross-checked with an independent Python script |
| Downloads with SHA-1 verification, retry, atomic replace | ✅ Unit tested with mock network | `DownloadTests` |
| Launch argument planning (offline or Microsoft profile) | ✅ Unit tested | Used by the in-app launch |
| Settings persistence, runtime discovery, Mach-O arch checks | ✅ Unit tested | |
| SwiftUI app (versions, install, diagnostics, logs) | ⚠️ Runs on iPhone 15 Pro Max / iOS 27.0: starts and loads the version list. Rest untested | [docs/FINAL_BUILD_REPORT.md](docs/FINAL_BUILD_REPORT.md) |
| IPA | ⚠️ Unsigned arm64 IPA; installed via Sideloadly (free Apple ID) | Startup only tested on device |
| Java runtime on iOS | ✅ Smoke test passed on iPhone 15 Pro Max / iOS 27 with StikDebug JIT | `docs/evidence/2026-10-16-java-smoke-test.log`; Minecraft itself not attempted |
| OpenGL ES on Metal (ANGLE, built from source) | ✅ Native and Java (LWJGL 3.3.3) tests passed on iPhone 15 Pro Max / iOS 27 | `docs/evidence/2026-10-16-angle-gl-test.log`, `…-lwjgl-gles-test.log` |
| Desktop OpenGL (GL 4.0 via MobileGlues on ANGLE) | ✅ Native and Java (LWJGL `GL33`) tests passed on iPhone | `docs/evidence/2026-10-16-*desktopgl*.log`; one MobileGlues context per launch |
| GLFW window/input bridge (app's own GLFW 3.4 API) | ✅ Passed on iPhone: window, context, touch→mouse, landscape, close | `docs/evidence/2026-10-16-glfw-*.log`; hardware keyboard untested; on-screen game controls reported working (2026-10-17); custom layouts (Controls tab) working on device (2026-10-17) |
| Mod loaders (Fabric, Quilt) | ✅ Fabric 1.21.11 and 26.1 installed from the in-app picker and run on device (2026-10-18); Quilt built, not yet tried on device | Picker on install; modded versions get their own game folder. Forge/NeoForge: later |
| Mod manager (mods, resource packs, shader packs) | ✅ On device: Fabric API + Essential imported from Files and loaded on Fabric 1.21.11 (50 mods, 2026-10-18) | Add from Files, switch on/off (`.disabled`), remove; reads Fabric/Quilt/Forge/NeoForge metadata |
| Modrinth browse and install (with dependencies) | ✅ On device (2026-10-18): Sodium, Iris (bringing Sodium as its dependency), Photon, BSL and MakeUp installed from the in-app browser into Fabric 1.21.11 | Search filtered to the version's Minecraft version and loader; required dependencies resolved; SHA-1 verified; replaces older copies. No API key |
| Modrinth modpacks (`.mrpack`, Fabric and Quilt) | ✅ On device (2026-10-18): Fabulously Optimized 13.6.0 (Minecraft 26.1.2, Sodium 0.9 + Iris) installed from the browser, launched and played after MobileGlues patches 0012–0014 | Versions → Modpacks: browse Modrinth or import a .mrpack from Files. Each pack becomes its own version with its own game folder; NeoForge/Forge packs are refused for now |
| Mod update checks | ✅ On device (2026-10-18): Essential 1.4.1.1 → 1.5.1 found and updated in place | Checked by file hash when a mods / packs tab opens; releases are never offered a beta; old file removed only after the new one is verified |
| Shader packs (Iris) | ✅ On device (2026-10-18): BSL and MakeUp Ultra Fast render correctly (water, hand, items, entities) after MobileGlues patches 0009 and 0011; stable at render distance 8 (2.2 GB of the 3.4 GB iOS limit). Packs needing compute shaders (Photon, Noble, Mellow, Visual Vibrance) cannot run on OpenGL ES 3.0 | iPhone has OpenGL ES 3.0 only. The Shader packs tab has a "Shaders in game" switch (Iris `enableShaders`) to recover |
| Microsoft account sign-in | ✅ Works on device (2026-10-17) | login.live.com web sign-in as Amethyst does (or your own approved Azure ID): [docs/MICROSOFT_SIGN_IN.md](docs/MICROSOFT_SIGN_IN.md). Tokens only in the Keychain |
| Java 8 / 17 / 21 / 25 runtimes, LWJGL 2 (lwjglx), FreeType, LWJGL 3.4.1 | ✅ On device: 1.16.5 (Java 8 + gl4es), 1.20.1 (Java 17), 1.21.11 (Java 21), 26.1 (Java 25 + LWJGL 3.4.1) run | Supported: 1.13 – 26.1.2. 26.2 is refused (black screen: shader link failure, paused); 26.3+ (SDL + Vulkan) refused; ≤1.12.2 not pursued | Covers 1.0 – 26.2 on paper; 26.3+ (SDL + Vulkan) is refused |
| **Launch Minecraft 1.20.1** | ⚠️ **Starts, reaches title screen, creates and joins a world, saves and exits** | `docs/evidence/2026-10-16-minecraft-1.20.1-first-launch.log`; not playable yet |

## Build kinds — do not confuse
- **Unit-tested core**: `swift test` on macOS. Says nothing about iOS.
- **Simulator build**: compiles and runs the UI in the iOS Simulator. A JIT/JVM is impossible to verify there.
- **Unsigned IPA** (`build/ipa/Voxelium-unsigned.ipa`): it cannot be installed until it is signed.
- **Development-signed build**: signed by your Apple ID in Xcode and installable on your registered iPhone. A free Apple ID's signature expires after 7 days.
- **Device-tested**: startup and the version-list download only (iPhone 15 Pro Max, iOS 27.0, 2026-10-15).

## Building
Requirements: macOS with Xcode 16+ (tested setup: Xcode 27.0). Accept the license once:
```bash
sudo xcodebuild -license accept
```
Core tests:
```bash
swift test
```
Simulator build:
```bash
xcodebuild -project App/Voxelium.xcodeproj -scheme Voxelium -destination 'generic/platform=iOS Simulator' build
```
Unsigned device IPA (output in `build/ipa/`, with a `.sha256` and an `.info` file):
```bash
scripts/build-ipa.sh
```

## Installing on your iPhone
Player guide (sideloading, StikDebug JIT, sign-in, mods, shaders, memory): **[docs/INSTALL.md](docs/INSTALL.md)**.

Developers building from source: open `App/Voxelium.xcodeproj` in Xcode, choose your Personal Team and a unique bundle ID on the Voxelium target, and Run on a phone with Developer Mode on. Then start the app from StikDebug for JIT. `scripts/build-ipa.sh` builds the unsigned IPA. The native dependencies come from the `scripts/build-*.sh` and `scripts/fetch-runtime.sh` scripts, run before the first build; `scripts/collect-licenses.sh` refreshes the notices.

## Licence
GPL-3.0. See [LICENSE](LICENSE), [NOTICE.md](NOTICE.md) and [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) (the licences of everything the app bundles; also in the app under Diagnostics → About). The project is not affiliated with ZalithLauncher, Mojang or Microsoft.

## Roadmap
Design notes: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Progress and evidence: [docs/ENGINEERING_LOG.md](docs/ENGINEERING_LOG.md).

| Stage | Contents | Status |
|---|---|---|
| Milestones 1–7 | Core, downloads, JVM on iOS with JIT, OpenGL on Metal, input, launching Minecraft | ✅ Done (1.13 – 26.1 on device) |
| Phase 1 | Fabric and Quilt | ✅ Done (Quilt not yet tried on device) |
| Phase 2 | Mod manager, Modrinth browser, shader packs, memory work | ✅ Done |
| Phase 2, Part C | Modrinth modpacks, mod update checks, shader comfort (render-distance warning, memory gauge) | ✅ Done |
| Release 0.1 | Licences and credits, install guide, GitHub release | ⏳ Now |
| Phase 3 | Forge / NeoForge | After the first release |
| Later | CurseForge (with your own API key), Minecraft 26.2 and newer, game controllers and hardware keyboards, launcher update checks | Ideas |
