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
- **Commit `b8c0f21`:** the IPA was rebuilt from it (SHA-256 `f5b27b4e…8231`, unsigned).
- **First device install (user ran Sideloadly with a free Apple ID):** iPhone 15 Pro Max (iPhone16,2), iOS 27.0 (24A437), Developer Mode enabled, wired.
  - Installed as `io.github.zalithios.launcher.BANQ4R4Z6N`, version 0.1.0, display name "Zalith iOS". After the install, "Get More Ram" no longer appeared in `devicectl device info apps`; a free Apple ID can only keep 3 sideloaded apps at a time, which would explain it.
  - `devicectl device process launch` succeeded; the process was running (PID 58997).
  - `launcher.log`, copied off the device, shows two clean startups with no errors and `JIT/debugger attached: false`, as expected without StikDebug.
  - The app downloaded `config/version_manifest_v2.json` on the device; copied back, it parses to 919 versions, latest release 26.3.
  - Not yet checked: on-device install of a game version, UI interactions, and behaviour with StikDebug attached.
- **First on-device game install (user tapped Install at about 20:11 local time):** the files on the device belong to **1.21.11**, not 1.20.1 (adjacent rows in the list). The user most likely tapped the wrong row.
  - In place: all 47 game files (client jar 29.7 MB, asset index 29, `client-1.21.2.xml`, 44 library jars), matching `zalith-cli plan 1.21.11`.
  - Assets: **1013 of 4591** objects (expected count taken from Mojang's index 29), all written at 20:12, and no progress after that.
  - **Cause: my `devicectl device process launch --terminate-existing` at 20:12:57 killed the app mid-install.** This is not a downloader failure. Lesson: never launch with `--terminate-existing` while the user may be using the app.
  - `launcher.log` had no errors, because successful downloads aren't logged.
- **Bug found from that partial install:** the app marked a version "Installed" as soon as its JSON existed, so the half-finished 1.21.11 showed as installed.
  - Fix: `GameInstaller` writes `versions/<id>/.zalith-install-complete` only when every file is verified, and removes it at the start of each run. The app now checks that marker.
  - New `InstallerTests` cover an interrupted install followed by a resume, and a failed repair clearing the marker. 56/56 tests pass.
  - The IPA was rebuilt (SHA-256 `1b53f66b…2944`); it is not yet installed on the device.
- **Open risk (not yet tested):** the downloads use a plain `URLSession`, so iOS will likely suspend them if the app goes to the background. A full asset install currently needs the app kept in the foreground. A background `URLSession` is the proper fix.
- **1.20.1 install on device (20:17–~20:20 local, old build, the fixed IPA was not sideloaded):** files copied off the device and compared with Mojang's index 5 and the 1.20.1 JSON:
  - assets: all **3575/3575** present;
  - client jar 22 MB;
  - the 38 classpath libraries the planner expects (the other 50 JSON entries are LWJGL/natives, excluded on purpose);
  - the asset index.

  The downloader verifies SHA-1 before moving each file into place, so presence implies a verified file. This is the first full-size real-network install verified on a device. The app stayed in the foreground; background behaviour is still untested.
- **The user reported "it cannot open the game version".** `launcher.log` shows "Prepare launch plan" tapped 4× for 1.20.1 (missing files: 0) and once for 1.21.11. That is the intended limit of this build: it only builds the JVM command line. There is no JVM, LWJGL or GL layer, so nothing can start the game. The UI should say this more clearly.
- **Milestone 5, first JVM attempt on device (13:59 UTC):** StikDebug 3.1.9 failed on iOS 27 ("DDI mount failed", "connection error"). This matches StikDebug issues #464 and #469, fixed in 3.1.11. The user updated to 3.1.14 and rebooted, and StikDebug connected.
  - Launched from StikDebug: `CS_DEBUGGED=1`, and libjvm **loaded** (the bundled, Sideloadly-signed dylibs are accepted).
  - `JNI_CreateJavaVM` reached `Threads::create_vm` → `initialize_java_lang_classes`, then **crashed**: `JavaCalls::call_helper`, KERN_INVALID_ADDRESS at 0xd8, HotSpot `report_and_die` (crash file `ZalithIOS-2026-10-15-205920.ips`).
  - Cause, from disassembly of the bundled libjvm: `get_debug_jit_mapping` (with MirrorMappedCodeCache on iOS ≥ 19) calls `dlsym(RTLD_DEFAULT, "DeviceHasTXM")`, falling back to env `XNU_HAS_TXM=1`. Only if that is true does it request the code cache from the debugger via `BreakGetJITMapping` (`brk #0x69`); otherwise it uses plain `mmap`. The app exported neither, so the JVM ran with an unusable code cache.
  - My `needsScript` also required the "mirrored" flag (it was 0), so the extension script was never sent. `getppid()` said "no debugger" while StikDebug was attached, so it is not a reliable check here.
  - Also, two later normal launches wiped `jvm.log`, so HotSpot's own output from the crash is lost.
- **Fixes:**
  - export `DeviceHasTXM()` (verified in the export trie: `_DeviceHasTXM`) and set `XNU_HAS_TXM=1`;
  - TXM alone now triggers the JIT26 sequence;
  - the `brk #0x69` probe runs under a temporary SIGTRAP handler, so a missing debugger gives an error instead of a crash (handler verified on macOS arm64 only, not on iOS);
  - `jvm.log` is appended per run;
  - `-XX:ErrorFile` points to `logs/`.

  New IPA SHA-256 `e2467211…1fc2`. Not yet tested on the device.

## 2026-10-16
- **Retest with the fixed IPA (00:05 and 00:08 UTC):** launched from StikDebug 3.1.14, `CS_DEBUGGED=1`. Both runs **stopped safely before the JVM**: `jvm.log` says "JIT26 probe: no debugger caught the breakpoint". The SIGTRAP fallback worked on iOS 27, and there was no crash.
  - StikDebug granted JIT, but no JIT script was attached at that point.
- **Why, from StikDebug source (HEAD):**
  - `ScriptStore` keeps manual script assignments per bundle ID in UserDefaults.
  - `AutoScriptAssignments.swift` auto-assigns the built-in `universal.js` only to a fixed list of app names (Amethyst, MeloNX, UTM, …). "Zalith iOS" is not on it, so without a manual assignment StikDebug just enables JIT and detaches.
  - StikDebug's built-in `universal.js` (header dated 2026-03-29) is the same protocol as Amethyst's `UniversalJIT26.js`, plus a `continuesWithSignal` option.
- **Side observation:** the reinstall gave the app a new data container (`789D87E2…`), and the user was re-downloading game files. A brief network drop caused retried downloads (`NSURLErrorDomain -1005`). The retry logic handled it as designed.
- **The script was not visible in StikDebug 3.1.14's swipe actions.** From its source (`InstalledAppRows.swift`), "Assign Script" is in the long-press context menu of the app row on the Home tab. It only shows when `enableAdvancedOptions` is set, which defaults to on for iOS ≥ 19. The user assigned the built-in `universal.js` that way.
- **MILESTONE 5 PASSED ON DEVICE (00:16 UTC):** full output in `docs/evidence/2026-10-16-java-smoke-test.log`.
  - Probe answered `0x…690000e0` (universal script), and the extension was sent.
  - libjvm logged "Requesting 240 MB for JIT mapping", "Got JIT mapping 0x11e6b4000 from debugger", and the mirrored RW/RX mapping.
  - OpenJDK 64-Bit Server VM 17.0.20 started in-process with 6 CPUs and maxMemory 256 MB.
  - The hot loop took 9 ms (16 ms on the M4 Mac with JDK 26). This is consistent with JIT compilation, not proof of it; no `-XX:+PrintCompilation` run yet.
  - A worker thread ran, and the program printed `ZALITH_JAVA_OK`; `main` returned normally.
  - The app was still running afterwards (PID 1862), with no hs_err file and no new crash report.
  - The two other crash reports (2026-10-15 21:00:46 and 2026-10-16 06:49:20) both predate this build and have the same HotSpot abort signature as the first crash.
- **Still unverified:**
  - a second JVM run per process (JNI does not allow it);
  - long runs and memory pressure under a free account (no increased-memory entitlement);
  - what happens after StikDebug detaches when more code-cache space is needed. The debugger detaches after the single mapping request, so the 240 MB reservation must last the whole run.
