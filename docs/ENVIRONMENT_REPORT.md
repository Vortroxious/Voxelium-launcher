# Environment Report

Commands were run on 2026-10-15. Everything listed was observed directly. Nothing here is assumed.

## Host
| Item | Result | Command |
|---|---|---|
| OS | macOS 27.0 (build 26A428), Darwin 27.0.0 | `sw_vers`, `uname -a` |
| CPU | Apple M4, arm64 | `sysctl -n machdep.cpu.brand_string` |
| RAM | 16 GiB (17179869184 bytes) | `sysctl -n hw.memsize` |
| Free disk | 14 GiB at start of session (93% used); 16 GiB after Xcode install | `df -h` |

## Toolchains
| Tool | Status |
|---|---|
| Swift | 6.4 (swiftlang-6.4.0.34.1), from Command Line Tools at session start |
| swift-testing | Worked under CLT. Later runs failed with "plugin for module 'TestingMacros' not found", then with "You have not agreed to the Xcode license agreements" once Xcode became the active developer dir (see ENGINEERING_LOG) |
| Xcode | **Not installed at session start.** The user installed Xcode 27.0 (27A266a) mid-session. `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`. Platforms present: iPhoneOS, iPhoneSimulator (and others) |
| Xcode license | Accepted by the user mid-session; `xcodebuild -checkFirstLaunchStatus` → 0 |
| iOS SDK | iPhoneOS 27.0 (24A430) |
| Simulator runtimes | **None installed** (`xcrun simctl list runtimes` is empty) |
| Java | Oracle JDK 26 (build 26+35-2893), arm64 |
| Kotlin / Gradle / Android SDK | Not installed (not needed for this project) |
| cmake / ninja / brew / ldid / xcodegen | Not installed |
| git | 2.54.0 |
| python3 | /usr/bin/python3 (CLT, 3.9) |

## Signing and devices
| Item | Result |
|---|---|
| Code-signing identities | `security find-identity -v -p codesigning` → **0 valid identities** |
| Provisioning profiles | none (`~/Library/MobileDevice/Provisioning Profiles` absent) |
| Connected iPhone | Not detected. `devicectl` was unavailable before Xcode. The user reports owning an iPhone and a free Apple ID |

## Network
These hosts were reachable: github.com / api.github.com, piston-meta.mojang.com, assets.angelauramc.dev.

## Consequences
- The pure-Swift core (`VoxeliumCore`) builds and tests on macOS.
- An iOS `.app` and IPA need the Xcode license accepted first. Signing additionally needs an Apple ID added in Xcode → Settings → Accounts.
- Physical-device testing needs the iPhone connected and Developer Mode enabled.
