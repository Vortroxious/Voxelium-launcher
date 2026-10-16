# Porting Feasibility: Gates A–H

Status values: **PASS** (verified here), **FAIL** (verified blocker), **UNKNOWN** (not yet tested).
Overall: Minecraft Java on iOS is *plausible*, because Amethyst-iOS exists and is maintained. **This project has run Java on an iPhone (2026-10-16) but has not run any part of the game.**

## A. Can a Java runtime execute on iOS? — PASS (smoke test, 2026-10-16)
- Verified: OpenJDK 17.0.20 (AngelAuraMC iOS build) bundled in the IPA, started with `JNI_CreateJavaVM` inside the app on an iPhone 15 Pro Max running iOS 27.0. It ran a test program to completion (`docs/evidence/2026-10-16-java-smoke-test.log`). This needs gate H.
- Verified facts:
  - Upstream's JREs are Android builds and unusable on iOS.
  - Prebuilt iOS arm64 JREs 8/17/21/25 are published by AngelAuraMC; the download URLs returned HTTP 200.
- Not verified: the build provenance beyond the publisher's URL (no checksum is published; the hash is pinned on first download); whether the interpreter alone (no JIT) is usable; behaviour under memory pressure.
- iOS prohibits writable+executable memory for unentitled apps, so HotSpot's JIT needs a debugger-attached process (CS_DEBUGGED) or equivalent.
- Test: unpack a JRE into `runtimes/`, `dlopen` `libjvm.dylib`, call `JNI_CreateJavaVM`, run a class printing `System.getProperty("java.version")`.
  - `MachO.isLoadableOnIOSDevice` (implemented) checks the binaries first.
- Remaining: real workloads (Minecraft) and memory limits on a free account.

## B. Can the native libraries be built for arm64-iOS? — UNKNOWN
- LWJGL core, OpenAL and the GL layer must be iOS dylibs/frameworks signed with the app (iOS refuses unsigned dylibs loaded at runtime).
- Natives must therefore be **bundled in the IPA**, not downloaded.
- Requires Xcode (now installed, license pending).

## C. Can LWJGL's required functionality be provided? — UNKNOWN
- Upstream's approach (which works on Android): replace `org.lwjgl.glfw.GLFW` with a Java shim whose window/input calls go to the host app (`CallbackBridge`).
- PojavLauncher-iOS used the same design on iOS.
- Not attempted here.

## D. Can rendering work on iOS/Metal? — UNKNOWN
- Facts: iOS has no desktop OpenGL; OpenGL ES is deprecated but still present; Metal is the supported API.
- Minecraft 1.17+ needs OpenGL 3.2 core, so a translation layer is mandatory. Candidates: MobileGlues, gl4es→GLES, ANGLE(Metal).
- No candidate has been built or tested.

## E. Input (touch, keyboard, mouse, controller)? — UNKNOWN
- UIKit provides touch; GameController.framework provides keyboard, mouse and controllers.
- Mapping these to GLFW callbacks is straightforward in principle, but nothing is implemented.

## F. Assets and libraries download and management — PASS (macOS unit tests)
- `ZalithCore` parses real Mojang manifest, version and asset index files, and plans downloads.
- Downloads are SHA-1-verified, retried and placed atomically.
- Covered by unit tests with a mock transport.
- **Not yet run on an iPhone.** A live end-to-end install on macOS is a manual step (`zalith-cli install`).

## G. Package, sign, install, test on iPhone — PASS (development sideload)
- Verified: unsigned IPA built by `scripts/build-ipa.sh`, signed and installed by the user with Sideloadly (free Apple ID), launched on an iPhone 15 Pro Max running iOS 27.0.
- A free Apple ID gives 7-day development certificates (3 apps max).
- Development signing adds `get-task-allow`, which JIT-via-debugger needs.
- `increased-memory-limit` / `extended-virtual-addressing` may not be grantable to free accounts (unverified).
- Without them, Jetsam limits may kill a JVM running Minecraft.

## H. Does the JIT workflow work? — PASS for this device (2026-10-16)
- Verified: StikDebug 3.1.14, with its built-in `universal.js` assigned to the app (long-press → Assign Script). The app runs a probe, sends Amethyst's extension script, and exports `DeviceHasTXM()`. libjvm then gets a 240 MB mirrored JIT mapping from the debugger. StikDebug 3.1.9 failed on iOS 27 (DDI/connection errors).
- StikDebug describes itself as a JIT enabler for iOS 17.4+.
- Amethyst's README lists StikDebug, SideStore, AltStore and TrollStore with differing requirements (Wi-Fi/pairing file).
- The app includes a `CS_DEBUGGED` check (Diagnostics tab). This flag is a prerequisite only: on recent iOS versions and devices the debugger must also service JIT memory requests, which is beyond this check.
- JIT alone does not make Minecraft run; gates A–E must also pass.

## Conclusion
Gates A, F, G and H have passed on one device: iPhone 15 Pro Max, iOS 27.0, free Apple ID, StikDebug 3.1.14. Gates B–E (LWJGL natives, OpenGL on Metal, window and input) are the remaining high-risk work, and Milestone 6 must prove them before any Minecraft launch attempt.
