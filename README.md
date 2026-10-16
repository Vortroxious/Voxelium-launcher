# ZalithIOS (working name)

An experimental iOS launcher for Minecraft: Java Edition, inspired by [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) 2.6.1.

> **This app cannot launch Minecraft yet.** It can browse Mojang's version list, download and verify game files, and run a small Java test program on a real iPhone (with JIT from StikDebug). Rendering the game on iOS is still unsolved. See [docs/PORTING_FEASIBILITY.md](docs/PORTING_FEASIBILITY.md).

## Feature status
| Feature | Status | Evidence |
|---|---|---|
| Version manifest / version JSON / asset index parsing | ✅ Unit tested (macOS) | `swift test`, real Mojang fixtures |
| Library rule evaluation, LWJGL filtering, classpath planning | ✅ Unit tested (macOS) | Counts cross-checked with an independent Python script |
| Downloads with SHA-1 verification, retry, atomic replace | ✅ Unit tested with mock network | `DownloadTests` |
| Launch argument planning (offline profile) | ✅ Unit tested | Produces a command line only; nothing is executed |
| Settings persistence, runtime discovery, Mach-O arch checks | ✅ Unit tested | |
| SwiftUI app (versions, install, diagnostics, logs) | ⚠️ Runs on iPhone 15 Pro Max / iOS 27.0: starts and loads the version list. Rest untested | [docs/FINAL_BUILD_REPORT.md](docs/FINAL_BUILD_REPORT.md) |
| IPA | ⚠️ Unsigned arm64 IPA; installed via Sideloadly (free Apple ID) | Startup only tested on device |
| Java runtime on iOS | ✅ Smoke test passed on iPhone 15 Pro Max / iOS 27 with StikDebug JIT | `docs/evidence/2026-10-16-java-smoke-test.log`; Minecraft itself not attempted |
| LWJGL / OpenGL→Metal / input | ❌ Not started | Gates B–E |
| Microsoft account sign-in | ❌ Not started | |
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
