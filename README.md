# ZalithIOS (working name)

An experimental iOS launcher for Minecraft: Java Edition, inspired by [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) 2.6.1.

> **This app cannot launch Minecraft yet.** It can browse Mojang's version list and download and verify game files. Starting Java and rendering the game on iOS are unsolved milestones. See [docs/PORTING_FEASIBILITY.md](docs/PORTING_FEASIBILITY.md).

## Feature status
| Feature | Status | Evidence |
|---|---|---|
| Version manifest / version JSON / asset index parsing | ✅ Unit tested (macOS) | `swift test`, real Mojang fixtures |
| Library rule evaluation, LWJGL filtering, classpath planning | ✅ Unit tested (macOS) | Counts cross-checked with an independent Python script |
| Downloads with SHA-1 verification, retry, atomic replace | ✅ Unit tested with mock network | `DownloadTests` |
| Launch argument planning (offline profile) | ✅ Unit tested | Produces a command line only; nothing is executed |
| Settings persistence, runtime discovery, Mach-O arch checks | ✅ Unit tested | |
| SwiftUI app (versions, install, diagnostics, logs) | ⚠️ Compiles for Simulator and device; never run | [docs/FINAL_BUILD_REPORT.md](docs/FINAL_BUILD_REPORT.md) |
| IPA | ⚠️ Unsigned arm64 IPA built | Not signed, installed or device-tested |
| Java runtime on iOS | ❌ Not started | Gate A |
| LWJGL / OpenGL→Metal / input | ❌ Not started | Gates B–E |
| Microsoft account sign-in | ❌ Not started | |
| Mod loaders, resource packs, shaders | ❌ Not started | `inheritsFrom` profiles are rejected explicitly |

## Build kinds — do not confuse
- **Unit-tested core**: `swift test` on macOS. Says nothing about iOS.
- **Simulator build**: compiles and runs the UI in the iOS Simulator. A JIT/JVM is impossible to verify there.
- **Unsigned IPA** (`build/ipa/ZalithIOS-unsigned.ipa`): it cannot be installed until it is signed.
- **Development-signed build**: signed by your Apple ID in Xcode and installable on your registered iPhone. A free Apple ID's signature expires after 7 days.
- **Device-tested**: none so far.

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

**JIT:** the app's Diagnostics tab shows whether a debugger is attached. Launching from Xcode attaches one. StikDebug (iOS 17.4+) can attach one on-device. JIT is only needed once the Java runtime exists, so it is not required for anything this build does.

## Licence
GPL-3.0. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). The project is not affiliated with ZalithLauncher, Mojang or Microsoft.

## Roadmap
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Next is Milestone 5: a JVM "hello world" on a real iPhone with JIT.
