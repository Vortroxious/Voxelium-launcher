# Architecture

## Language and framework choice
- **Swift + SwiftUI**: the native iOS toolchain, with no bridging runtime. Kotlin Multiplatform was considered and rejected: upstream's Kotlin is entangled with Android APIs (Compose, Room, Hilt, Context), so very little could be shared, and KMP adds a Gradle/Kotlin toolchain that is not installed here.
- **VoxeliumCore is a SwiftPM library** with no UIKit dependency, so it builds and tests on macOS with `swift test`.
- **Objective-C/C (planned)** for the JNI/JVM bridge and the GL context, because JNI and dlopen-based loading are C APIs.

## Modules
| # | Module | Location | Status |
|---|---|---|---|
| 1 | iOS app & UI | `App/Voxelium` (SwiftUI) | Source written; not yet compiled (Xcode license) |
| 2 | Version & asset management | `VoxeliumCore/Manifest`, `Launch/GameFilePlanner`, `Launch/GameInstaller` | Implemented, unit tested |
| 2b | Download manager | `VoxeliumCore/Download` | Implemented, unit tested |
| 3 | Java runtime integration | `VoxeliumCore/Runtime` (discovery, Mach-O checks); JVM bridge planned in `App/Native` | Discovery only |
| 4 | Native library / ABI management | `MachO.swift` | Header checks only |
| 5 | Rendering & window/input | planned: CAMetalLayer + GL translation layer + GLFW shim | Not started |
| 6 | Game process lifecycle | `LaunchPlanner` produces the command line | Plan only; nothing executed |
| 7 | Accounts | `OfflineIdentity` | Offline only; Microsoft OAuth not started |
| 8 | Logging & diagnostics | `VoxeliumCore/Logging`, Diagnostics tab | Implemented |

## Data flow (install)
```
version_manifest_v2.json ──► VersionManifest.Entry(url, sha1)
      └─► <id>.json (sha1-verified) ──► VersionInfo
              ├─► GameFilePlanner.installItems → client.jar, libraries (rules + LWJGL filter), asset index, log config
              └─► AssetIndex → assetItems (objects/xx/hash)
                         └─► DownloadManager.run (bounded concurrency, retry, SHA-1, atomic move)
```

## Data flow (launch, planned)
```
LaunchPlanner.plan → LaunchPlan (classpath, JVM args, game args, Java major)
   └─► [planned] JVM bridge: dlopen(runtimes/jre-17/lib/server/libjvm.dylib) → JNI_CreateJavaVM → main()
          └─► [planned] LWJGL GLFW shim ⇄ UIKit view (CAMetalLayer) + GL→Metal layer
```

## Platform rules
- Mojang has no iOS OS key. Rules are evaluated as `linux`/`aarch64` (`RulePlatform.iOSDefault`), and the `org.lwjgl` libraries are excluded. This matches upstream's effective behaviour (see SOURCE_AUDIT).
- Natives are never taken from Mojang. They must be bundled and signed in the IPA.

## Data directory
The app's `Documents/` folder (visible in Files → On My iPhone → Voxelium; since after 0.1.0, which used the hidden `Application Support/Voxelium/`) contains `minecraft/{versions,libraries,assets,saves,…}`, `runtimes/`, `logs/`, `config/` and `controls/`. `AppPaths.migrateIfNeeded(from:to:)` moves the old folder on first start without overwriting anything. All metadata-derived paths go through `AppPaths.resolve`, which rejects absolute paths and `..` traversal.

## Alternatives considered
- **Porting the Android app with a compatibility layer**: rejected; there is no Android runtime on iOS.
- **Forking Amethyst-iOS**: the fastest route to a running game, and GPL-compatible. It was not chosen as the base because the task asks for a ZalithLauncher-inspired port with audited provenance. It remains the main reference for gates A–D and H, and a fallback if they fail.
