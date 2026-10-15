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
