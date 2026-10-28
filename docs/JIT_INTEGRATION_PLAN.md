# JIT in Voxelium: research and implementation plan

Research and planning only, 2026-10-28. No code was changed.

**What this covers:** how far Voxelium can get and manage JIT by itself, and what it still has to leave to other apps or a computer.

**What it builds on:**
- Voxelium 2.2 already turns on JIT through StikDebug, and that was tested on the iPhone (section 1).
- [JITLESS_RESEARCH.md](JITLESS_RESEARCH.md) found that a version of Voxelium **without** JIT is not realistic.

Each claim carries a label, as in that document:

- **[verified]**: checked in this repository, on the test iPhone, or in a primary source: project source code, Apple documentation, or a repository's own files.
- **[likely]**: supported by secondary sources or strong inference, but not tested here.
- **[unknown]**: no good evidence; it needs a prototype or a device test.

References such as [S3] point to the source list at the end.

---

## 1. Feasibility assessment

### Summary

| Question | Answer | Label |
|---|---|---|
| Can Voxelium turn JIT on using only public iOS APIs? | **No.** Only a debugger attached through Apple's developer services (`debugserver` from the Developer Disk Image) can mark a sideloaded app's process as debugged and let it make memory executable. On iOS 26 with TXM, a debugger script must also set up each executable region. | verified |
| Can it happen without the user doing anything at all? | **No.** At minimum a VPN app (LocalDevVPN) has to be connected, Developer Mode has to be on, and a pairing file has to be imported once. In the StikDebug path, StikDebug also asks for confirmation by default. | verified |
| Can it be **built into Voxelium**, with no StikDebug app and no app switch? | **Probably, through "Built-in StikJIT".** StikJIT is a framework that runs inside a helper app extension shipped with the host app. It still needs LocalDevVPN, a pairing file and Developer Mode. It has not been tried in Voxelium. | verified (design), unknown (in Voxelium) |
| Can it work without a computer after the first setup? | **For JIT, yes:** the pairing file is made once on a computer, then everything runs on the phone. **For signing, no** with Sideloadly and a free Apple ID: the app must be re-signed every 7 days, and Sideloadly needs a computer for that. SideStore can re-sign on the phone. | verified (JIT design), likely (SideStore refresh) |
| Can Voxelium ship on the App Store with JIT? | **No.** JIT is not offered to App Store apps except browser engines (EU, and Japan per secondary sources). Downloading and running Minecraft's code also conflicts with guideline 2.5.2. | verified |
| Does JIT depend on the Minecraft version or mod loader? | **No.** JIT is per process. Every bundled Java (8, 17, 21, 25) uses the same JIT hooks, so vanilla, Fabric, Quilt, Forge and NeoForge all get it the same way. | verified |
| Can JIT be turned on automatically, with no user step, in the future? | Not with what is known today. Every method needs a debugger session that the user starts or allows. **Don't promise automatic JIT.** | verified (today) |

### What already exists in Voxelium 2.2 [verified]

**Start from StikDebug** (since 0.1):
- StikDebug starts Voxelium already debugged.

**StikDebug hand-off** (2.2, `MinecraftLauncher.enableJITThroughStikDebug`):
1. When the user taps Play without JIT, Voxelium opens `stikjit://enable-jit?bundle-id=…&pid=…`.
2. On TXM devices, the link also carries `script-data` (the base64url `UniversalJIT26.js`).
3. Voxelium then checks `CS_DEBUGGED` every 200 ms, for up to 120 s.
4. On the test phone, JIT was on 4 s after Play.

**The JIT26 protocol** (`JITSupport.m`, `JVMBridge.m`):
1. On TXM devices, the JVM bridge first sends a probe (`brk #0x69`) to check that the script is attached.
2. It sends `UniversalJIT26Extension.js` (`brk #0xf00d`, x16=2), which teaches the script the libjvm's `brk #0x69` request.
3. It asks the script to detach after the first such request.
4. libjvm then gets one 240 MB mirrored code-cache mapping.

**Smooth exit:**
- Uses the JNI `exit` hook and `UIApplication suspend`.

**Where it has been tested:** one iPhone 15 Pro Max on iOS 27.0, with StikDebug 3.1.14–3.1.15.

### The work left

The rest of this plan does not add JIT itself. It does three things:
1. **Makes the StikDebug path sturdier:** better checks and clearer errors.
2. **Adds an optional built-in path** that skips the app switch.
3. **Adds a setup and status experience** that explains each missing piece.

---

## 2. Technical research

### 2.1 How JIT works for a sideloaded iOS app

- **Apple's entitlement is private.** App processes can't map memory writable and executable without Apple's private `dynamic-codesigning` entitlement. A sideloaded app signed with a developer certificate can't get it. [verified: JITLESS_RESEARCH.md §1, [S9][S10]]
- **What a debugger changes.** Attaching a debugger sets `CS_DEBUGGED` on the process. From then on, on devices without TXM, the process may create executable mappings. [verified: `JITSupport.m` `VXJITDebuggerAttached`; StikJIT guide [S2]: "attaching and detaching the debugger is enough"]
  - **Requirements:** the app must be signed with `get-task-allow`. Development certificates from a free Apple ID include it. [verified: StikJIT guide [S2], StikDebug README [S1]]
- **The debugger comes from Apple's `debugserver`** in the Developer Disk Image, reached through lockdown and RemoteXPC/RSD. That needs:
  - a **pairing file**: the device's trust record for a "computer";
  - a **network route to the device's own services**: LocalDevVPN, a loopback VPN, provides it. StikJIT's default endpoint is `10.7.0.1:49152`.
  - [verified: StikJIT `Configuration` and guide [S2]; idevice README [S4]]
- **No process can debug itself.** A process that attaches a debugger to itself deadlocks, because the debugger stops every thread, including the one that would continue it. So the debugger must always be **another process**: StikDebug, a helper extension, or a computer. [verified: StikJIT guide [S2]]
- **iOS 26 and TXM (A15 and later, M2 and later).** The Trusted Execution Monitor works with SPTM [S11]. With it, the debug flag alone is not enough: each executable region must be prepared through the debug connection, by a JavaScript "JIT script" that the debugger runs. [verified: StikJIT guide Part 1 [S2]]
  - **Voxelium follows this already:** UniversalJIT26.js, plus its extension for libjvm's `brk #0x69`. [verified]
  - **Regions can't be added later.** The script detaches after setup, so any executable region requested afterwards can't be prepared. libjvm's single 240 MB code cache must last the whole run. [verified: guide "Preallocate executable regions before detaching"; ENGINEERING_LOG.md line 81]

### 2.2 iOS version timeline

| iOS | What works | Label |
|---|---|---|
| 16.x (Voxelium's minimum) | Only computer-based tools (AltServer/AltJIT, SideStore's own JIT). StikDebug and StikJIT need 17.4. | verified (StikDebug's range) |
| 17.0 – 17.3 | Computer-based: SideJITServer ("for iOS 17 with a … computer on the same WiFi") [S6] | verified (description) |
| 17.4 – 18.x | StikDebug and StikJIT: debugger attach and detach is enough on these versions. Some reports say the computer-based tools only work up to 18.3.2. | verified (StikDebug range [S1]); likely (18.4 note) |
| 26.0 – 26.3 | StikDebug with per-app JIT scripts on TXM devices: "developers must update their apps". Other enablers don't work on 26 [S8]. | verified |
| 26.4+ | Early reports of JIT breaking [S5]. StikJIT 1.7 installs the new "cryptex" Developer Disk Image on 26.4+ [S2]. | verified (StikJIT notes), likely (fixed for most users) |
| 27.0 | Works on our iPhone 15 Pro Max with StikDebug 3.1.15. A fork reports the disk-image mount failing on one other chip [S12]. | verified (our phone), unknown (other phones) |
| Later | Apple can close this path in any update. It has already changed it in 17.0 (CoreDevice), 17.4, 26.0 (TXM) and 26.4 (pairing and disk image). | likely (from the rows above) |

### 2.3 Existing tools

| Project | What it does | Status (2026-10-28) | Licence | Fit for Voxelium | Label |
|---|---|---|---|---|---|
| **StikDebug** [S1] | On-device JIT enabler (iOS 17.4+), built on idevice. Handles `stikdebug://` and `stikjit://` `enable-jit` links with `bundle-id`, `pid`, `script-data` or `script-name`, and asks for confirmation. | Active: 3.1.15 released 2026-10-15; last push 2026-10-19. Not on the App Store. | AGPL-3.0 | **Used now** (2.2 hand-off). We only open its link and don't embed its code, so its licence doesn't apply to Voxelium. | verified |
| **StikJIT** [S2][S3] | An XCFramework that turns on JIT for **another process** through the RSD tunnel. Bundles idevice, `universal.js` and `legacy.js`. Must run in a helper app extension. Downloads and mounts the Developer Disk Image itself. | Active: v1.7.0, last push 2026-09-27; built with Xcode 27; deployment target 17.4. | MPL-2.0 (idevice MIT; the scripts keep their own licences) | **Best route to a built-in experience** (section 3). | verified |
| **idevice** [S4] | Rust library for lockdown, RSD, CoreDeviceProxy, debug_proxy, the disk-image mounter and heartbeat; C FFI. | Active: pushed 2026-10-27. Pre-1.0, with breaking changes each release. | MIT | Use only through StikJIT. Calling it directly would mean re-implementing the disk-image and script handling. | verified |
| **SideJITServer** [S6] | Python server on a computer (pymobiledevice3) that enables JIT over Wi-Fi or USB, for iOS 17. | Last push 2025-01-21; no JIT26 script support found. | GPL-3.0 | Mention only as a manual option for iOS 17.0–17.3. It needs a computer. | verified (status), likely (no iOS 26) |
| **JitStreamer-EB** [S7] | Remote JIT server over WireGuard, for iOS 17.4+. | **Archived** 2025-03-22; LiveContainer lists it as deprecated [S8]. | — | Don't use. | verified |
| **LiveContainer** [S8] | Runs apps inside a container. Supports StikDebug and SideStore as JIT enablers; says only the StikDebug options work on iOS 26+. | Active | AGPL-3.0 | Shows how other apps handle enablers. Built-in StikJIT can't work inside LiveContainer [S2]. | verified |
| **Amethyst-iOS** [S13] | Minecraft launcher. Voxelium's StikDebug hand-off, JIT26 helpers and smooth exit come from it. | Active: pushed 2026-10-17 | GPL-3.0 | Reference, already credited. | verified |
| **SideStore** [S14] | On-device re-signing through a loopback VPN, plus JIT for older iOS versions. | Active | AGPL-3.0 | Recommend it for refreshing without a computer. LiveContainer notes its JIT link "is not implemented yet". | verified (repo), likely (refresh) |

### 2.4 Two findings from the StikJIT and StikDebug source

- **Voxelium's script matches StikJIT's.** StikJIT's bundled `universal.js` and Voxelium's `UniversalJIT26.js` have the same command table: x16 = 0 detach, 1 prepare region, 2 evaluate a script, plus the `0x69` hook. Only the header lines differ. So Built-in StikJIT with `.universal`, followed by Voxelium's existing extension step, should work **without rebuilding libjvm**. [verified (script text), likely (end to end)]
- **The link could be much shorter.** StikDebug accepts `script-name=universal.js` [verified: `HomeView.swift` lines 208–222], so the StikDebug link could name the script instead of carrying about 13 KB of base64. Voxelium would rely on StikDebug's own copy of the script. That's a small simplification, not a must.

### 2.5 App Store, signing and entitlements

- **App Store.** Guideline 2.5.2: apps may not "download, install, or execute code which introduces or changes features or functionality of the app". Guideline 4.7 allows emulators to download games, but grants no JIT. Guideline 2.5.1 requires public APIs only. [verified [S9]]
  - **Apple's JIT entitlements are only for browser engines:** BrowserEngineKit in the EU, and reportedly Japan from iOS 26.2. Apple refused it to iSH. [verified (EU) [S10]; likely (Japan)]
  - **So:** Voxelium stays a sideloaded app.
- **`get-task-allow`.** It must be in the installed app's signature. A free or paid development certificate through Sideloadly, AltStore or SideStore includes it. Distribution signing (App Store, Ad Hoc, enterprise) does **not**. [verified: StikJIT guide; likely for the per-tool details]
- **An app extension costs one more App ID.** A free Apple ID can register only 10 App IDs per 7 days, and installs are limited to about 3 apps [S15].
  - **Unknown:** whether Sideloadly counts the extension against the 3-app limit, and whether it signs a nested `.appex` correctly with a free Apple ID.
- **A VPN of our own isn't needed.** A VPN needs the Network Extension entitlement, which free accounts probably can't get. LocalDevVPN (App Store) provides the tunnel, so Voxelium doesn't need its own. [likely]
- **Local network.** StikDebug declares `NSLocalNetworkUsageDescription` to find "this iPhone's Remote Pairing service" [verified: StikDebug Info.plist]. A helper extension may need the same. [unknown]

### 2.6 Security implications

- **The pairing file is a credential.** It gives lockdown-level access to the phone: install apps, start a debugger, read diagnostics.
  - **Exposure today:** the project sets `INFOPLIST_KEY_UIFileSharingEnabled`, but the built 2.2 app has only `LSSupportsOpeningDocumentsInPlace`; Xcode doesn't generate `UIFileSharingEnabled` from that setting [verified: Info.plist of `Voxelium-2.2-unsigned.ipa`]. If file sharing is turned on later, StikJIT's suggested location, `Documents/StikJIT/pairingFile.plist`, would show in Finder and the Files app.
  - **Plan:**
    1. Import it with the document picker.
    2. Store it in the **Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), not in Documents.
    3. Pass it to the helper in memory.
    4. Let the helper write a temporary file only for the operation, and delete it afterwards.
    5. Never log it.
  - This follows the project rule against storing secrets in plain text.
- **`get-task-allow` lets any paired debugger attach to Voxelium.** That is true of every sideloaded JIT app. Document it, and don't store secrets in process memory longer than needed. The Microsoft tokens are already in the Keychain.
- **JIT scripts run with full control of the process.**
  - Ship exactly one developer-chosen script, bundled in the app.
  - Never accept a script from the user, a URL or the network. This is also StikJIT's rule [S2].
- **The incoming link.** Any app can open `stikjit://enable-jit` for Voxelium's bundle ID. StikDebug's confirmation (on by default) protects against that. Recommend users keep it on.
- **Developer Disk Image downloads.** StikJIT fetches the image from Apple, needing the network. Voxelium itself sends nothing to new servers.

---

## 3. Recommended architecture

**One coordinator, three methods the user chooses between, one readiness check.** This is the shape StikJIT recommends, and it keeps today's working paths.

```text
                 ┌──────────────────────────── Voxelium app (host) ─────────────────────────────┐
  Play ──► JITCoordinator (Swift, @MainActor)                                                   │
                 │  preflight: iOS version · get-task-allow · TXM state · pairing file · VPN   │
                 │  chosen method (one, no silent fallback):                                     │
                 │   ├─ Wait for debugger   → poll CS_DEBUGGED                    (exists)       │
                 │   ├─ StikDebug link      → open stikdebug://enable-jit…, poll  (exists, 2.2)  │
                 │   └─ Built-in StikJIT    → start helper, send pid + pairing data ─────┐       │
                 │  readiness: CS_DEBUGGED, then on TXM the JIT26 probe + extension       │       │
                 │  (JVMBridge.m, unchanged) → JVM starts                                 │       │
                 └────────────────────────────────────────────────────────────────────┼───────┘
                                                                                      ▼
                     VoxeliumJIT.appex (helper extension, iOS 17.4+): StikJIT.xcframework
                     prepareDevice → mount DDI (cached per boot) → debugserver attach to host pid
                     → run universal.js (host's brk calls are answered) → detach
                                     │ RSD tunnel 10.7.0.1 via LocalDevVPN (separate App Store app)
```

### Parts

**Native Swift / Objective-C in Voxelium**, using public APIs plus a few private interfaces the app already relies on:
- `JITCoordinator`: the state machine, the method setting, preflight checks, user-facing status and errors.
  - It replaces the ad-hoc check in `MinecraftLauncher.launch`.
  - Its pure logic (states, link building) lives in VoxeliumCore so it can be unit-tested.
- **Preflight:**
  - iOS version: `ProcessInfo`;
  - TXM: existing `VXJITGetFlags`, plus StikJIT's `isTXMPresent` when the helper is available;
  - `get-task-allow`: `SecTaskCopyValueForEntitlement` (private);
  - whether a tunnel interface is up: `getifaddrs`, as a hint only;
  - whether StikDebug is installed: `canOpenURL` with `LSApplicationQueriesSchemes`.
- **Readiness:** `VXJITDebuggerAttached`, plus the existing JIT26 probe and extension in `JVMBridge.m`. Unchanged.
- **Pairing-file storage:** Keychain plus the document picker.
- **Setup checklist and JIT status UI** (section 4, Phase 3).

**Helper app extension** (new target, deployment target 17.4):
- embeds StikJIT;
- runs `enableJIT` on one serial queue;
- keeps the disk-image cache in its own Library folder.

**Outside Voxelium, which it can't replace:**
- LocalDevVPN (the tunnel);
- the pairing file, made once on a computer with `idevice_pair` or similar;
- Developer Mode;
- Apple's Developer Disk Image servers;
- the signing tool (Sideloadly, SideStore);
- StikDebug, for the link method.

### How the host starts the helper [unknown]

StikJIT "does not provide or launch the helper extension. The app owns that integration" [S2]. The host-to-extension channel is the riskiest part of the design:

- **Candidate A:** start the extension with the private `NSExtension` API (`extensionWithIdentifier:error:` and `beginExtensionRequestWithInputItems:completion:`). Pass the pid and pairing data in the `NSExtensionItem` userInfo. Get progress back through Darwin notifications, and the result through the request's completion. [unknown: not tried; private API]
- **Candidate B:** an App Group file exchange. This needs the App Groups capability, which may not be available to free Apple IDs. [unknown]
- **Spike first:** Phase 2 picks one by prototype. Ask in the idevice community which extension point and IPC existing integrators use [S2].

### What stays the same

- `JITSupport.m`, the JIT26 probe and extension sequence, `UniversalJIT26.js`, and the libjvm builds stay unchanged in every method.
- Every method ends at the same readiness check, so the Java, LWJGL, renderer and loader code doesn't change.

---

## 4. Implementation roadmap

Phases are ordered by value and risk. Each one ends with a phone test (section 7) and a decision.

### Phase 1: make the current StikDebug path sturdier (2–3 days)

1. **`JITCoordinator`.** Move the 2.2 logic (`enableJITThroughStikDebug`) into it. Add a **Cancel** button while waiting, and check again immediately when Voxelium becomes active, instead of only every 200 ms.
2. **Is StikDebug installed?** Add `stikdebug` and `stikjit` to `LSApplicationQueriesSchemes` and check with `canOpenURL` before opening.
   - Switch to the documented `stikdebug://` scheme; StikDebug registers both [verified].
   - If StikDebug is missing, show the setup guide **instead of** a failed attempt.
3. **Separate error messages**, each with its own fix:
   - StikDebug not installed;
   - no answer within the time limit: VPN off, no pairing, or the user didn't confirm;
   - attached, but the script did not answer (the JIT26 probe trapped);
   - the wrong script answered (probe mismatch);
   - the debugger detached early.
4. **Check `get-task-allow` at startup.** If it's missing, say "reinstall with Sideloadly using a development (Apple ID) signature" before the user ever taps Play.
5. **Look into the unexplained first-start stops.** These are the logged stops after the flags line and before the JIT probe (NeoForge, 2026-10-23 and 2026-10-24). Add log lines around the probe so the next one can be diagnosed.
6. **Optional:** send `script-name=universal.js` instead of `script-data` when StikDebug's copy is known to match; keep `script-data` as the default.

### Phase 2: Built-in StikJIT spike (4–6 days, decides go or no-go)

Use a throwaway branch and a separate test bundle ID. Answer these questions on the iPhone:
1. Does Sideloadly with a free Apple ID sign and install Voxelium with a nested `.appex`? How many App IDs does that use?
2. Can the host start the extension, pass its pid and the pairing data, and get the result back (Candidate A, then B)?
3. Does `StikJIT.enableJIT(script: .universal)` attach to Voxelium? After that, the JIT26 probe should return `0x690000E0`, the extension should be accepted, and libjvm should get its 240 MB mapping.
4. Does it work on Wi-Fi with LocalDevVPN, and on mobile data with the Airplane Mode trick? Does it survive a reboot, which needs a new disk-image mount?
5. What is the size and memory cost of StikJIT plus idevice in the IPA, and in the extension, which has a lower memory limit?

**Go** if 1–4 pass. **No-go** otherwise: keep StikDebug as the method and record why.

### Phase 3: Built-in StikJIT in the app (1.5–2 weeks, if Phase 2 says go)

1. **Targets:**
   - `VoxeliumJIT.appex` with StikJIT, built from source by `scripts/build-stikjit.sh` like the other dependencies;
   - add it to `scripts/build-ipa.sh` and its contents checks.
2. **Pairing file:**
   - document picker import, Keychain storage, delete and replace;
   - show the imported file's name and date, never its contents.
3. **JIT settings section:**
   - **JIT method:** Built-in, StikDebug, or Wait for debugger;
   - status: pairing, TXM (Present, Not present, Unknown), VPN hint, StikDebug installed;
   - **Prepare JIT** with readiness and reason, **Reset Developer Disk Image**, and **Force JIT script** (off by default).
   - Hide **Built-in** below iOS 17.4 and inside LiveContainer (`LC_HOME_PATH`).
4. **Play with Built-in:**
   - show progress stages, for example "Connecting… Mounting developer image… Attaching… JIT on";
   - show StikJIT's real error text (`StikJITError`), not a generic "failed";
   - never switch to another method silently.
5. **Licences:** add StikJIT (MPL-2.0), idevice (MIT) and the scripts' licences to `THIRD_PARTY_NOTICES.txt` and `collect-licenses.sh`.
   - Check every StikJIT file for an "Incompatible With Secondary Licenses" notice, which would stop combining it with GPL-3.0. The licence text alone doesn't decide this. [unknown]

### Phase 4: first-run setup guide (3–4 days)

A checklist screen, opened from the JIT status and from any failed Play:

| Step | How Voxelium checks it | Fix offered |
|---|---|---|
| Developer Mode | Can't be read with a public API. Inferred: the app runs, and StikJIT's readiness errors mention it. | Link to the steps in Settings |
| `get-task-allow` | `SecTaskCopyValueForEntitlement` | "Reinstall with a development signature" |
| LocalDevVPN connected | Hint from `getifaddrs` (tunnel interface); confirmed by `prepareDevice` reachability | Open LocalDevVPN (App Store link) |
| Pairing file | Keychain item present; `prepareDevice` result | Import button; how to make one with `idevice_pair` |
| StikDebug (link method) | `canOpenURL` | Install link |
| Network for the disk image | `prepareDevice` stage | Wi-Fi, or the Airplane Mode trick |

### Phase 5: docs and release (1–2 days)

- **Docs:** update README and INSTALL with the methods and the choice between them; record each device pass in the engineering log; write release notes.
- **Recommended default:** Built-in if Phase 3 shipped; otherwise StikDebug.

**Total:** Phase 1 alone is about 3 days. With Built-in StikJIT, about 4–5 weeks of work, plus device time.

---

## 5. Required APIs, dependencies and permissions

### APIs

| Need | API | Public? | Notes |
|---|---|---|---|
| Open StikDebug | `UIApplication.open`, `canOpenURL` | Public | `LSApplicationQueriesSchemes`: `stikdebug`, `stikjit` |
| Debugger attached? | `csops(CS_OPS_STATUS)` → `CS_DEBUGGED` | **No** (syscall not in the SDK) | Already used |
| TXM present? | `/private/preboot` scan, `MGGetSInt64Answer("ChipID")` fallback | **No** | Already used; StikJIT has its own check |
| `get-task-allow` check | `SecTaskCreateFromSelf`, `SecTaskCopyValueForEntitlement` | **No** (SPI on iOS) | From the StikJIT guide |
| JIT26 calls | `brk #0xf00d` / `brk #0x69` traps | — | Crash unless the script is attached; already guarded by the probe |
| Start the helper extension | `NSExtension` request API | **No** (private) | Phase 2 spike |
| Store the pairing file | Keychain Services | Public | |
| Import the pairing file | `UIDocumentPickerViewController` | Public | |
| VPN hint | `getifaddrs` | Public | Hint only |
| Smooth exit | JNI `exit` hook, `UIApplication suspend` | **No** (`suspend` is private) | Already used |

### Dependencies

- **New:** StikJIT 1.7.x (MPL-2.0) with idevice (MIT), built from source. Pin a commit, because idevice breaks its API on each release.
- **External apps the user installs:**
  - StikDebug (AltSource or IPA) for the link method;
  - LocalDevVPN (App Store);
  - Sideloadly or SideStore.
- **On a computer, once:** `idevice_pair` to make the pairing file.

### Permissions and entitlements

- `get-task-allow = true` in the installed signature, from development signing.
- Helper extension: its own App ID and provisioning, under the same team.
- Possibly `NSLocalNetworkUsageDescription` (Phase 2 decides).
- No Network Extension entitlement (LocalDevVPN covers it), no App Groups unless Candidate B is chosen, and no paid account required.

### What public iOS APIs cannot do

1. Make memory executable without a debugger.
2. Attach a debugger to its own process (deadlock).
3. Provide the local tunnel to the phone's developer services without Network Extension, which is effectively paid-only. Voxelium depends on LocalDevVPN for it.
4. Create a pairing record on the phone itself. The first pairing needs a computer.
5. Read whether Developer Mode is on.
6. Read Voxelium's own entitlements, TXM state or code-signing flags; these use private interfaces.
7. Start your own app extension on demand.
8. Keep a sideloaded app signed beyond 7 days with a free Apple ID.

---

## 6. Risks, limitations and fallbacks

| Risk | Likelihood | Impact | Mitigation and fallback |
|---|---|---|---|
| An iOS update breaks debugger-based JIT, as 26.4 briefly did | Medium per major release | Play impossible | The launcher stays usable without JIT for accounts, downloads, mods and worlds. Show the exact error and link StikDebug's status page. Pin a known-good StikJIT; follow StikDebug releases. Tell users to wait before updating iOS. |
| StikDebug changes or drops `enable-jit` links | Low | Hand-off fails | Keep Wait for debugger (start from StikDebug); Built-in if shipped. |
| Sideloadly can't sign the extension, or the App ID limit blocks free users | Medium | Built-in unavailable | Ship the extension as optional, or offer a second IPA without it. StikDebug remains. |
| Starting the helper relies on private `NSExtension` API | Medium | Built-in breaks after an iOS update | Detect the failure; switch the setting only with the user's consent. |
| 240 MB code cache fills in large modpacks, since regions can't be added after detach | Low–medium | Slower play ("CodeCache is full", compiler off) | Log code-cache use at exit (`-XX:+PrintCodeCache`). Test big modpacks. Later: prepare more regions before detaching, which needs libjvm work. |
| The pairing file leaks through Documents or Files | Medium if stored in Documents | Device-level access | Keychain storage (section 2.6). |
| Memory: the helper extension, or the debugger session during start | Low | Start fails | The helper exits after detaching. Measure in Phase 2. |
| StikDebug's confirmation, VPN and Airplane Mode steps confuse users | High | Support load | Setup checklist and specific errors (Phases 1 and 4). |
| Endorsement: the StikDebug team says it "generally decline[s]… low-quality substantially AI-generated projects" [S2] | — | No listing or support from them; using the link or the MPL framework is not affected | Optional. Ask only if the integration is polished. |
| Tested on one iPhone | High | Unknown failures on A12–A14, iPad, iOS 17/18 | Testers (section 7). |

**Hard limits, which can't be removed:**
- No App Store release.
- No JIT without a VPN app and a pairing file.
- No first pairing without a computer.
- Free Apple ID: re-signing every 7 days.

---

## 7. Testing plan for real iPhones

### Devices

| Group | Example | Why | Have it? |
|---|---|---|---|
| TXM, iOS 27 | iPhone 15 Pro Max (A17 Pro) | Current test phone | Yes |
| TXM, iOS 26.x | Any A15+ on 26.3 and 26.4+ | Covers the 26.4 pairing and disk-image change | Needs a tester |
| No TXM on iOS 26 (A12) / TXM only from 27 (A13–A14) | iPhone XS, iPhone 11, iPhone 12 | `hasTXM` uses a chip list for these; the script must not be sent where it isn't needed | Needs a tester |
| iOS 17.4 – 18.x | Any | Built-in StikJIT's lower bound; debugger attach alone, no script | Needs a tester |
| iOS 16 – 17.3 | Any | Must show "use Start from StikDebug / a computer tool", not crash | Optional |

### Setup per device

- **Install:** the test IPA with Sideloadly and a free Apple ID; once with SideStore if possible.
- **Before each run:** confirm the installed build with `xcrun devicectl device info apps`.
- **After each run:** collect `launcher.log` and `jvm.log` with `devicectl device copy from`.
- **Record:** the time from Play to "JIT is on", and the JIT26 probe result.

### Scenarios (each method that is offered)

1. **Happy path.** Cold start from the Home Screen, then Play: Fabric 1.21.11, vanilla 26.3 (Vulkan), NeoForge 1.21.1 (first start, which runs the installer processors), Forge 1.20.1, and one Java 8 version (1.16.5). Each must reach a world and quit smoothly.
2. **Second start in the same app session.** Must be refused clearly ("one JVM per app launch").
3. **Missing pieces**, one at a time: StikDebug not installed, VPN off, no pairing file, an invalid or old pairing file, Developer Mode off, no `get-task-allow` (distribution-signed build). Each must give its own message and no crash.
4. **User actions:** decline the StikDebug confirmation; press Cancel while waiting; send Voxelium to the background during the wait; lock the phone during the wait.
5. **Network:** Wi-Fi; mobile data with the Airplane Mode trick; no network at all (disk image not cached); right after a reboot (disk image must mount again).
6. **Long session:** a 30-minute world with a large modpack. Check code-cache use and memory (`[VXMEM]`), and that nothing breaks after detach.
7. **Updates:** install the new IPA over the old one with the same Apple ID. Settings, the pairing file in the Keychain, worlds and mods must stay.
8. **Built-in only:** the first run downloads and mounts the disk image; Reset Developer Disk Image works; Built-in is hidden inside LiveContainer.

### Pass criteria

- Every offered method reaches the world in all of scenario 1 on each available device.
- Every failure in scenarios 3–5 gives a specific message that names its fix, and the app stays usable.
- The pairing file never appears in logs or in Documents.
- No regression in 2.2's numbers: JIT within about 5 s on Wi-Fi with StikDebug, and memory unchanged.

---

## Sources

All accessed 2026-10-28 unless noted.

- [S1] StikDebug repository, README, `Info.plist` and `Views/HomeView.swift` (AGPL-3.0; release 3.1.15, 2026-10-15): https://github.com/StikDebug/StikDebug
- [S2] StikJIT `INTEGRATION.md` (Part 1: iOS 26 JIT; Part 2: StikDebug link and Built-in StikJIT): https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md
- [S3] StikJIT repository: `Sources/StikJIT.swift`, `StikJITError.swift`, `Resources/universal.js`, `project.yml`, LICENSE (MPL-2.0; last push 2026-09-27): https://github.com/StikDebug/StikJIT
- [S4] idevice (MIT; last push 2026-10-27): https://github.com/jkcoxson/idevice
- [S5] PiunikaWeb, "iOS 26.4 breaks a key JIT workaround for sideloading" (2026-03-26): https://piunikaweb.com/2026/03/26/ios-26-4-may-break-jit-for-sideloaded-apps/
- [S6] SideJITServer (GPL-3.0; last push 2025-01-21): https://github.com/nythepegasus/SideJITServer
- [S7] JitStreamer-EB (archived): https://github.com/jkcoxson/JitStreamer-EB
- [S8] LiveContainer, JIT support guide: https://livecontainer.github.io/docs/guides/jit-support
- [S9] Apple, App Review Guidelines (2.5.1, 2.5.2, 2.5.6, 4.7): https://developer.apple.com/app-store/review/guidelines/
- [S10] Apple, "Using alternative browser engines in the European Union": https://developer.apple.com/support/alternative-browser-engines/. iSH, "iSH, JIT, and EU": https://ish.app/blog/ish-jit-and-eu (via JITLESS_RESEARCH.md)
- [S11] Apple Platform Security, operating-system integrity (SPTM, TXM; A15+/M2+): https://support.apple.com/guide/security/sec8b776536b
- [S12] StikDebug27 fork (iOS 27 disk-image report, unverified): https://github.com/Xarber/StikDebug27
- [S13] Amethyst-iOS (GPL-3.0): https://github.com/AngelAuraMC/Amethyst-iOS
- [S14] SideStore (AGPL-3.0): https://github.com/SideStore/SideStore
- [S15] AltStore FAQ, error codes (10 App IDs per 7 days): https://faq.altstore.io/altstore-classic/error-codes
- **This repository:**
  - `App/Voxelium/Native/JITSupport.{h,m}`, `JVMBridge.m`, `MinecraftLauncher.swift` (`enableJITThroughStikDebug`);
  - `Sources/VoxeliumCore/Launch/StikDebugJIT.swift`;
  - `App/Voxelium/Resources/UniversalJIT26*.js`;
  - `docs/ENGINEERING_LOG.md` (2026-10-15 to 2026-10-24 JIT entries);
  - `docs/JITLESS_RESEARCH.md`.
