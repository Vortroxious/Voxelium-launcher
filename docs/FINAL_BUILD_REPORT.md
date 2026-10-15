# Build Report — 2026-10-15

**Result: an unsigned development IPA was built and passed the structural checks below. It is NOT signed, NOT installed, NOT device-tested, and cannot launch Minecraft. It is not release-ready.**

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
| IPA signed | **No** | 0 signing identities on this Mac |
| IPA installed on iPhone | No | |
| Launched on physical iPhone | No | |
| Java runtime executed | No | not implemented (gate A) |
| Minecraft main menu / gameplay | No | not implemented |

## IPA
| Field | Value |
|---|---|
| Path | `build/ipa/ZalithIOS-unsigned.ipa` |
| Size | 341,581 bytes |
| SHA-256 | `5eb43dc8ffdb4cff588203d1fe2550f8067af6e11a055219e95e078dd010cc70` |
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
- Source revision: **no commits yet**. The build came from an uncommitted working tree.

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
- Not verified on any device or simulator. UI behaviour is untested at runtime.
- No real large-file download test: the multi-file downloader has been exercised only with the mock transport plus one small live metadata file.
- No JVM, LWJGL, GL or input. Microsoft sign-in is not implemented.
- Free Apple ID signing expires after 7 days. Increased-memory entitlements may be unavailable (unverified).
- The project name is close to "ZalithLauncher" (GPLv3 §7 terms, see NOTICE.md).

## Next steps to reach "device-tested"
1. In Xcode, set your Personal Team and a unique bundle ID, connect the iPhone, enable Developer Mode, and Run.
2. Record the iOS version, device model, and Diagnostics-tab output in `docs/ENGINEERING_LOG.md`.
3. Install version 1.20.1 on the device and record the download result.
