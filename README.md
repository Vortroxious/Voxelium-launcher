# Voxelium

An experimental iOS launcher for Minecraft: Java Edition, inspired by [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) 2.6.1.

> **Experimental.** Voxelium runs Minecraft: Java Edition **1.13 – 26.3** on an iPhone (tested on an iPhone 15 Pro Max / iOS 27): Java 8/17/21/25 in-process, OpenGL via MobileGlues or gl4es on ANGLE (Metal), or Vulkan (Mesa KosmicKrisp, with Zink for OpenGL versions; iOS 26+), with on-screen touch controls, custom layouts, haptics, sound and Microsoft sign-in. It needs JIT through StikDebug and is sideloaded (no App Store build). Performance is unmeasured; 26.2+ and 1.12.2 and older are not supported yet. See [docs/FINAL_BUILD_REPORT.md](docs/FINAL_BUILD_REPORT.md).

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
| Mod loaders (Fabric, Quilt, Forge, NeoForge) | ✅ Fabric 1.21.11 and 26.1 on device (2026-10-18). ✅ NeoForge 21.1.264 (1.21.1) and Forge 47.4.10 (1.20.1) set up on first launch and joined a world on device (2026-10-21). 🧪 NeoForge 1.21.11 and Forge 1.21.11 reach the title screen on macOS through the same path; not yet run on device. Quilt built, not yet tried on device | Picker on install; modded versions get their own game folder. Forge (Minecraft 1.17+) and NeoForge (1.20.2+) finish setting up inside the game's Java on the first launch (a minute or two) |
| Mod manager (mods, resource packs, shader packs) | ✅ On device: Fabric API + Essential imported from Files and loaded on Fabric 1.21.11 (50 mods, 2026-10-18) | Add from Files, switch on/off (`.disabled`), remove; reads Fabric/Quilt/Forge/NeoForge metadata |
| Modrinth browse and install (with dependencies) | ✅ On device (2026-10-18): Sodium, Iris (bringing Sodium as its dependency), Photon, BSL and MakeUp installed from the in-app browser into Fabric 1.21.11 | Search filtered to the version's Minecraft version and loader; required dependencies resolved; SHA-1 verified; replaces older copies. No API key |
| Modrinth modpacks (`.mrpack`) | ✅ On device (2026-10-18): Fabulously Optimized 13.6.0 (Minecraft 26.1.2, Sodium 0.9 + Iris) installed from the browser, launched and played after MobileGlues patches 0012–0014 | Versions → Modpacks: browse Modrinth or import a .mrpack from Files. Each pack becomes its own version with its own game folder. Forge/NeoForge packs install too (not yet tried on device) |
| Mod update checks | ✅ On device (2026-10-18): Essential 1.4.1.1 → 1.5.1 found and updated in place | Checked by file hash when a mods / packs tab opens; releases are never offered a beta; old file removed only after the new one is verified |
| Shader packs (Iris) | ✅ On device (2026-10-18): BSL and MakeUp Ultra Fast render correctly (water, hand, items, entities) after MobileGlues patches 0009 and 0011; stable at render distance 8 (2.2 GB of the 3.4 GB iOS limit). Packs needing compute shaders (Photon, Noble, Mellow, Visual Vibrance) cannot run on OpenGL ES 3.0 | iPhone has OpenGL ES 3.0 only. The Shader packs tab has a "Shaders in game" switch (Iris `enableShaders`) to recover |
| Data folder in Files, Worlds screen | ✅ On device (2026-10-18): 0.1.0 data moved to Documents, a world imported and played in Fabric 1.21.11 + BSL | Files → On My iPhone → Voxelium shows `minecraft/`, `logs/` … (moved from the hidden folder on first start). **Play → Worlds…** imports a world folder or `.zip`, shares one as a `.zip`, deletes. [Bringing your worlds](docs/INSTALL.md#bringing-your-worlds) |
| Microsoft account sign-in | ✅ Works on device (2026-10-17) | login.live.com web sign-in as Amethyst does (or your own approved Azure ID): [docs/MICROSOFT_SIGN_IN.md](docs/MICROSOFT_SIGN_IN.md). Tokens only in the Keychain |
| Java 8 / 17 / 21 / 25 runtimes, LWJGL 2 (lwjglx), FreeType, LWJGL 3.4.1 | ✅ On device: 1.16.5 (Java 8 + gl4es), 1.20.1 (Java 17), 1.21.11 (Java 21), 26.1 (Java 25 + LWJGL 3.4.1) run | Supported: 1.13 – 26.3. 26.2 on MobileGlues needs patch 0015; 26.3 runs on Vulkan (SDL3, LWJGL 3.4.3, iOS 26+); ≤1.12.2 not pursued | Minecraft 26.2 and 26.3 on device: 2026-10-24 |
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

This takes about 15 minutes the first time. You need a Mac for steps 1–3; after that, everything happens on the iPhone.

### What you need

**On your Mac**

| What | Where to get it |
|---|---|
| **Sideloadly**: installs apps on your iPhone with your Apple ID | [sideloadly.io](https://sideloadly.io/index.html) |
| **idevice_pair**: makes the pairing file StikDebug needs | [github.com/jkcoxson/idevice_pair/releases](https://github.com/jkcoxson/idevice_pair/releases) |
| **StikDebug** (`.ipa`): turns on JIT, which Java needs | [github.com/StikDebug/StikDebug/releases/latest](https://github.com/StikDebug/StikDebug/releases/latest) |
| **Voxelium** (`Voxelium-2.2-unsigned.ipa`) | [github.com/Vortroxious/Voxelium-launcher/releases/latest](https://github.com/Vortroxious/Voxelium-launcher/releases/latest) |
| *Optional:* **GetMoreRam** (`.ipa`): only if the game keeps closing from low memory (see [Troubleshooting](#troubleshooting)) | [github.com/hugeBlack/GetMoreRam/releases](https://github.com/hugeBlack/GetMoreRam/releases) |

Also: a USB cable for your iPhone, and an Apple ID (a free one works).

**On your iPhone**

- **LocalDevVPN** from the App Store: [apps.apple.com/app/localdevvpn/id6755608044](https://apps.apple.com/us/app/localdevvpn/id6755608044)
- **Developer Mode** turned on (step 2 shows where)
- A Minecraft: Java Edition account (Microsoft account)

### Step 1: Install StikDebug and Voxelium with Sideloadly
1. Connect your iPhone to the Mac with the cable. If the phone asks **Trust This Computer?**, tap **Trust**.
2. Open **Sideloadly**, sign in with your Apple ID, drag the **StikDebug** `.ipa` into it, and click **Start**. Wait until it says it's done.
3. Do the same with the **Voxelium** `.ipa`.

> With a free Apple ID, sideloaded apps stop opening after 7 days. Sideload them again with Sideloadly to refresh them.

### Step 2: Allow the apps on your iPhone
1. Turn on **Developer Mode**: **Settings → Privacy & Security → Developer Mode**. The iPhone restarts; after the restart, confirm with **Turn On**. (The option only appears once you've sideloaded an app.)
2. Trust your Apple ID: **Settings → General → VPN & Device Management**, tap your Apple ID under *Developer App*, then **Trust**.

### Step 3: Give StikDebug a pairing file
1. Keep the iPhone connected and unlocked. On the Mac, open **idevice_pair** and select your iPhone.
2. Create the pairing file and send it to StikDebug. idevice_pair can place it in StikDebug directly; if you save it as a `.plist` file instead, AirDrop it to your iPhone or put it in the Files app.
3. On the iPhone, open **StikDebug → Settings → Import Pairing File** and choose the `.plist`. (Skip this if idevice_pair already placed it in StikDebug.)

### Step 4: Open Voxelium (every time)
1. Open **LocalDevVPN** and turn the VPN **on**.
2. Open **Voxelium** from the Home Screen, like any app.

You don't need to assign a script in StikDebug or open Voxelium from it any more. Voxelium asks StikDebug for JIT when you start a game (step 5). Opening Voxelium from StikDebug, as before, still works.

### Step 5: Play
1. **Account** tab: **Sign in with Microsoft**, copy the code and finish signing in on the page that opens.
2. **Versions** tab: install a version (1.13 – 26.2, or 26.3 on iOS 26+). For mods, choose Fabric, Quilt, Forge or NeoForge when installing, or tap **Modpacks**.
3. Under **Installed**, tap **Play** and choose how to start.
   1. **StikDebug opens** and asks to enable JIT for Voxelium. Tap to confirm.
   2. **StikDebug switches back** to Voxelium, and Minecraft starts.
   3. **On iPhones with iOS 26,** Voxelium also sends StikDebug the JIT script it needs, so there's nothing to assign by hand.
   4. **On mobile data:** StikDebug's connection needs **Airplane Mode on**. Turn it on just before tapping Play, and off again once the game has started.

### Troubleshooting
- **StikDebug opens but Minecraft doesn't start:** make sure LocalDevVPN is on (and Airplane Mode, on mobile data), close Voxelium completely, open it again and tap Play. If it keeps failing, open StikDebug directly once, wait for it to connect, then try again. Starting Voxelium from StikDebug also works.
- **The game closes after a while (low memory):** lower the render distance to 8–10, especially with shaders. The gauge under **More** in game shows how full memory is. If it still happens, **GetMoreRam** can add Apple's *Increased Memory Limit* to Voxelium: install GetMoreRam with Sideloadly, sign in there with the same Apple ID, open **App IDs**, refresh, select Voxelium and add *Increased Memory Limit*, then install Voxelium again with the same Apple ID. GetMoreRam's own guide uses SideStore or AltStore for that reinstall; doing it with Sideloadly has not been tested.
- **Getting your worlds in or out:** use **Play → Worlds…** or Files → On My iPhone → Voxelium, with Minecraft closed. See [Bringing your worlds](docs/INSTALL.md#bringing-your-worlds).
- **The versions list doesn't load:** check your internet connection (and Airplane Mode, see step 5), then tap **Refresh**.

More about mods, shaders and memory: [docs/INSTALL.md](docs/INSTALL.md).

### Building from source
Open `App/Voxelium.xcodeproj` in Xcode, choose your Personal Team and a unique bundle ID on the Voxelium target, and Run on a phone with Developer Mode on; then start the app from StikDebug for JIT. `scripts/build-ipa.sh` builds the unsigned IPA. The native dependencies come from the `scripts/build-*.sh` and `scripts/fetch-runtime.sh` scripts, run before the first build; `scripts/collect-licenses.sh` refreshes the notices.

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
| Release 0.1 | Licences and credits, install guide, GitHub release | ✅ [Published](https://github.com/Vortroxious/Voxelium-launcher/releases/tag/v0.1.0) 2026-10-18 |
| Release 0.1.1 | Data folder in the Files app, Worlds screen (import, share, delete) | ✅ [Published](https://github.com/Vortroxious/Voxelium-launcher/releases/tag/v0.1.1) 2026-10-18 |
| Phase 3 | Forge / NeoForge | ✅ NeoForge 1.21.1 and Forge 1.20.1 (with Oculus shaders) work on device; modpacks and more versions to test |
| Release 1.0 | Forge and NeoForge | ✅ [Published](https://github.com/Vortroxious/Voxelium-launcher/releases/tag/v1.0) 2026-10-21 |
| Release 2.0 | Vulkan renderer (KosmicKrisp, Zink), Minecraft 26.3 (SDL3), renderer choice, bigger hotbar | ✅ [Published](https://github.com/Vortroxious/Voxelium-launcher/releases/tag/v2.0) 2026-10-24 |
| Release 2.1 | Minecraft 26.2 on MobileGlues (patch 0015: base-vertex draws through ANGLE's OES/EXT functions) and on Vulkan | ✅ Tagged 2026-10-24 ([release notes](docs/RELEASE_NOTES_2.1.md)) |
| Release 2.2 | Open Voxelium from the Home Screen: Play asks StikDebug for JIT (like Amethyst); smooth close after quitting | ⏳ Being prepared ([release notes](docs/RELEASE_NOTES_2.2.md)) |
| Later | CurseForge (with your own API key), game controllers and keyboards on the OpenGL path, launcher update checks | Ideas |
