# ZalithIOS (working name)

An experimental iOS launcher for Minecraft: Java Edition, inspired by [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) 2.6.1.

> **Experimental: Minecraft Java 1.20.1 has started on an iPhone** (offline account, JIT via StikDebug): title screen, world creation and joining a world on an iPhone 15 Pro Max / iOS 27. On-screen touch controls (Amethyst-style layout with haptics) and sound have been reported working on that phone (build 202610170123). Performance is unmeasured, only 1.20.1 has been tried, and builds are development-signed only. See [docs/PORTING_FEASIBILITY.md](docs/PORTING_FEASIBILITY.md).

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
| Microsoft account sign-in | ✅ Works on device (2026-10-17) | login.live.com web sign-in as Amethyst does (or your own approved Azure ID): [docs/MICROSOFT_SIGN_IN.md](docs/MICROSOFT_SIGN_IN.md). Tokens only in the Keychain |
| Java 8 / 17 / 21 / 25 runtimes, LWJGL 2 (lwjglx), FreeType, LWJGL 3.4.1 | ✅ On device: 1.16.5 (Java 8 + gl4es), 1.20.1 (Java 17), 1.21.11 (Java 21), 26.1 (Java 25 + LWJGL 3.4.1) run | Supported: 1.13 – 26.1.2. 26.2 is refused (black screen: shader link failure, paused); 26.3+ (SDL + Vulkan) refused; ≤1.12.2 not pursued | Covers 1.0 – 26.2 on paper; 26.3+ (SDL + Vulkan) is refused |
| **Launch Minecraft 1.20.1** | ⚠️ **Starts, reaches title screen, creates and joins a world, saves and exits** | `docs/evidence/2026-10-16-minecraft-1.20.1-first-launch.log`; not playable yet |
| Mod loaders, resource packs, shaders | ❌ Not started | `inheritsFrom` profiles are rejected explicitly |

## Build kinds — do not confuse
- **Unit-tested core**: `swift test` on macOS. Says nothing about iOS.
- **Simulator build**: compiles and runs the UI in the iOS Simulator. A JIT/JVM is impossible to verify there.
- **Unsigned IPA** (`build/ipa/ZalithIOS-unsigned.ipa`): it cannot be installed until it is signed.
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
xcodebuild -project App/ZalithIOS.xcodeproj -scheme ZalithIOS -destination 'generic/platform=iOS Simulator' build
```
Unsigned device IPA (output in `build/ipa/`, with a `.sha256` and an `.info` file):
```bash
scripts/build-ipa.sh
```

## Installing on your iPhone (free Apple ID)
1. Open `App/ZalithIOS.xcodeproj` in Xcode and go to Settings → Accounts → add your Apple ID.
2. On the ZalithIOS target, open Signing & Capabilities, pick your Personal Team, and change the bundle ID to something unique (e.g. `com.<you>.zalithios`).
3. Connect the iPhone, enable Developer Mode (Settings → Privacy & Security), then Run.
4. On the phone, trust the developer profile (Settings → General → VPN & Device Management).

Alternatively, sign the unsigned IPA with SideStore or AltStore.

**JIT (needed for the Java test):** these steps were verified on an iPhone 15 Pro Max running iOS 27.0 with StikDebug 3.1.14. Older StikDebug versions fail on iOS 27.
1. Before building, run `scripts/fetch-runtime.sh` to bundle the iOS Java runtime.
2. In StikDebug, open the Home tab, long-press **Zalith iOS** → **Assign Script** → `universal.js`.
3. Close Zalith iOS, then tap it in StikDebug to launch it with JIT. Leave StikDebug's script log sheet open.
4. In Zalith iOS, go to Diagnostics → **Run Java test**. Success shows `ZALITH_JAVA_OK`. The test can run once per app launch.

## Licence
GPL-3.0. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). The project is not affiliated with ZalithLauncher, Mojang or Microsoft.

## Roadmap
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Next is Milestone 5: a JVM "hello world" on a real iPhone with JIT.
