# Build Report — 2026-10-15

**Result: the IPA was built from commit `b8c0f21`. The user signed and installed it with Sideloadly (free Apple ID) on an iPhone 15 Pro Max running iOS 27.0. It starts and downloads Mojang's version list. It cannot launch Minecraft and is not release-ready.**

## Achievements (kept separate on purpose)
| Achievement | Status | Evidence |
|---|---|---|
| Source code written | Yes | `Sources/`, `App/`, `Tests/` |
| Unit tests passed | **Yes: 54 tests in 10 suites** | `swift test` → "Test run with 54 tests in 10 suites passed after 0.838 seconds." |
| Live network check (macOS) | Yes, metadata only | `zalith-cli plan 1.20.1` fetched the manifest and the 1.20.1 JSON. The JSON's SHA-1 matched `a5cf661d…` |
| App compiled: iOS Simulator (Debug) | **Yes**, BUILD SUCCEEDED, 0 project warnings | `build/logs/xcodebuild-sim.log` |
| App compiled: iOS device arm64 (Release) | **Yes**, BUILD SUCCEEDED, 0 project warnings | `build/logs/xcodebuild-Release.log` |
| App launched in Simulator | **No** | No simulator runtime installed (`simctl list runtimes` is empty); 11 GiB free disk |
| IPA packaged | **Yes, unsigned** | see below |
| IPA signed | **Yes, by Sideloadly** (free Apple ID; expires after 7 days) | The unsigned IPA in `build/ipa/` is still unsigned |
| IPA installed on iPhone | **Yes** | `devicectl device info apps` → `io.github.zalithios.launcher.BANQ4R4Z6N` 0.1.0 |
| Launched on physical iPhone | **Yes**: starts and stays running; version list downloaded | PID 58997; `launcher.log` has no errors; the cached manifest copied off the device parses to 919 versions |
| Game version install on device | **Yes: 1.20.1** (old build, app in foreground) | 3575/3575 assets, client jar, 38/38 classpath libraries present on device |
| JIT (debugger attached) | **Yes** | TXM path: 240 MB mirrored code-cache mapping obtained from the debugger |
| Java runtime executed | **Yes: smoke test on iPhone** (2026-10-16) | OpenJDK 17.0.20 in-process with JIT via StikDebug 3.1.14 + `universal.js`; printed `ZALITH_JAVA_OK`. See `docs/evidence/2026-10-16-java-smoke-test.log` |
| OpenGL ES via ANGLE (native test) | **Yes, passed on iPhone** (2026-10-16) | ANGLE Metal on A17 Pro GPU, GLES 3.0, pixel read-back exact, 59.2 fps. `docs/evidence/2026-10-16-angle-gl-test.log` |
| OpenGL ES via LWJGL (Java test) | **Yes, passed on iPhone** (2026-10-16) | Java → LWJGL 3.3.3 → ANGLE → Metal, GLES 3.0, pixel read-back exact. `docs/evidence/2026-10-16-lwjgl-gles-test.log` |
| Desktop GL via MobileGlues (native + Java/LWJGL) | **Yes, passed on iPhone** (2026-10-16, build 202610161548) | GL 4.0.0 MobileGlues 1.3.3 on ANGLE/Metal, exact pixels. `docs/evidence/2026-10-16-*desktopgl*.log` |
| GLFW bridge (window, context, input) | **Yes, passed on iPhone** (2026-10-16, build 202610161611) | 60 fps, exact pixels, 1476 cursor events from drags, landscape, close button. `docs/evidence/2026-10-16-glfw-*.log` |
| Minecraft reached the main menu | **Yes** (2026-10-16, build 202610161636) | Resource reload completed and a world was created from the title screen. `docs/evidence/2026-10-16-minecraft-1.20.1-first-launch.log` |
| Actual gameplay verified | **Partly**: joined a world, world saved on exit; on-screen controls, haptics, sound (OpenAL/CoreAudio) and camera look reported working by the user (2026-10-17, build 202610170123) | FPS not measured; the user reports controls and sound only, without logs of each control. `docs/ENGINEERING_LOG.md` 2026-10-17 |

## IPA
| Field | Value |
|---|---|
| Path | `build/ipa/ZalithIOS-unsigned.ipa` |
| Size | 341,581 bytes |
| SHA-256 | `f5b27b4e6a442985b7737957f155666a261ad222eaaf2a461ae9326e6ace8231` (rebuilt from `b8c0f21`) |
| Bundle ID | `io.github.zalithios.launcher` (change it to your own when signing) |
| Version | 0.1.0 (build 1) |
| Minimum iOS | 16.0 |
| Architecture | arm64; Mach-O LC_BUILD_VERSION platform 2 (iOS) |
| Contents | `Payload/ZalithIOS.app/{ZalithIOS, Info.plist, PkgInfo}`. ZalithCore is linked statically. No app icon |
| Code signature | `codesign -dv`: "code object is not signed at all" |
| Entitlements | none (development signing will add `get-task-allow`) |
| Linked private symbol | `_csops` (libSystem), used for debugger/JIT detection |

The SHA-256 and metadata are also written by the script to `build/ipa/ZalithIOS-unsigned.ipa.sha256` and `.info`.

## Build configuration
- macOS 27.0 (26A428), Apple M4. Xcode 27.0 (27A266a), iPhoneOS SDK 27.0 (24A430). Swift 6 language mode.
- Release, `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`.
- Source revision: `b8c0f2107bc8caeb5367f63f14110e27b759933d`.

## Exact commands
```bash
swift test
```
```bash
xcodebuild -project App/ZalithIOS.xcodeproj -scheme ZalithIOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build
```
```bash
scripts/build-ipa.sh
```

## Issues found and fixed during this build
- Swift 6 warning: `UIDevice.current` was used from a nonisolated context (`DeviceInfo.systemDescription`). Fixed by marking it `@MainActor`.
- iPad orientation warning. Fixed by separate iPhone and iPad orientation keys.
- The script's commit field printed garbage in a repo with no commits. Fixed.

## Known limitations / unresolved
- On the device: only startup and the version-list download are verified. UI interactions and game installs are untested.
- No real large-file download test: the multi-file downloader has been exercised only with the mock transport plus one small live metadata file.
- No JVM, LWJGL, GL or input. Microsoft sign-in is not implemented.
- Free Apple ID signing expires after 7 days. Increased-memory entitlements may be unavailable (unverified).
- The project name is close to "ZalithLauncher" (GPLv3 §7 terms, see NOTICE.md).

## Next steps
1. Milestone 6: LWJGL + GLFW bridge + an OpenGL-on-Metal layer (gates B–E).
2. Then Milestone 7: launch 1.20.1.
