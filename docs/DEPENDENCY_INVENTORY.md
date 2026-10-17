# Dependency Inventory

## This project (Voxelium)
| Dependency | Version | Source | License | Platforms | Notes |
|---|---|---|---|---|---|
| Swift stdlib / Foundation | Swift 6.4 toolchain | Apple | Apple SDK license | iOS 16+, macOS 14+ | |
| CryptoKit | SDK | Apple | Apple SDK license | iOS 13+, macOS 10.15+ | `Insecure.SHA1`, `Insecure.MD5` (integrity checks and offline UUID, not security) |
| SwiftUI | SDK | Apple | Apple SDK license | iOS 16+ | App target only |
| swift-testing | bundled with toolchain | Apple | Apache-2.0 | macOS (tests) | |

There are no third-party Swift packages. Native and Java components bundled in the app are listed below.

## Bundled or planned components for game launch
| Component | Candidate | License | Status |
|---|---|---|---|
| JVM for iOS arm64 | AngelAuraMC iOS OpenJDK 17.0.20 (`scripts/fetch-runtime.sh`, SHA-256 pinned) | GPL-2.0 + Classpath Exception (per the runtime's `legal/` files) | **Bundled; smoke test passed on device 2026-10-16** |
| JVMs for other versions | AngelAuraMC iOS OpenJDK 1.8.0_472, 21.0.8 and 25.0.4 (`scripts/fetch-runtime.sh`, SHA-256 pinned 2026-10-17). Each libjvm is an iOS (platform 2) arm64 build with the iOS 26 JIT hooks | GPL-2.0 + Classpath Exception (jre8: `LICENSE`/`ASSEMBLY_EXCEPTION`; 21/25: `legal/`) | **Bundled 2026-10-17; not yet run on device** |
| FreeType (lwjgl-freetype, Minecraft 1.20.5+) | FreeType `VER-2-13-3`, built for iOS by `scripts/build-freetype.sh` (no zlib/png/bzip2/harfbuzz/brotli) | FTL or GPL-2.0 (dual) | **Built, bundled; not yet run on device** |
| LWJGL 2 API (Minecraft 1.12.2 and older) | `lwjglx` binding of the AngelAuraMC LWJGL 3.3.3 fork (as ZalithLauncher2/Amethyst use) | BSD-3-Clause | **Built, bundled; not yet run on device** |
| LWJGL 3.4.1 (Minecraft 26.1 - 26.2) | AngelAuraMC/lwjgl3 `wip/rebase_3.4.1` `702c2102a287`, `LWJGL_SERIES=3.4.1 scripts/build-lwjgl.sh` | BSD-3-Clause | See ENGINEERING_LOG 2026-10-17 |
| GL on iOS (GLES provider) | ANGLE `33f8caff4b77`, Metal backend, built from source by `scripts/build-angle.sh` | BSD-3-Clause | **Built**; bundled; device test pending |
| Desktop GL on top of GLES | MobileGlues `f0fb4d32794a` + glslang 15.0.0, SPIRV-Tools, SPIRV-Cross 1.4.304.0, built by `scripts/build-mobileglues.sh` | LGPL-2.1 (deps Apache/MIT/BSD). FastSTL (no licence declared) is **removed** from our build: patch 0002 uses `std::unordered_map` | **Built**; bundled; device test pending |
| LWJGL Java + natives for iOS | LWJGL 3.3.3 from AngelAuraMC/lwjgl3 `6a564a8b4b14`, built by `scripts/build-lwjgl.sh` (Ant 1.10.18, libffi 3.4.8) | BSD-3-Clause (libffi MIT) | **Built**; bundled; Minecraft 1.20.1 runs on device (2026-10-17) |
| OpenAL | openal-soft 1.25.2, built by `scripts/build-openal.sh` (CoreAudio) | LGPL-2.0+ | **Bundled; sound confirmed on device 2026-10-17** |
| JIT enabling | StikDebug 3.1.14 + built-in `universal.js` (external app, AGPL-3.0); Amethyst's `UniversalJIT26Extension.js` bundled (GPL-3.0) | — | **Verified on iPhone 15 Pro Max / iOS 27.0** |

## Upstream ZalithLauncher2 2.6.1 (from `gradle/libs.versions.toml`, selected)
| Library | Version | License (per upstream README) | iOS usable? |
|---|---|---|---|
| Kotlin | 2.4.20 | Apache-2.0 | n/a (Swift chosen) |
| Android Gradle Plugin | 9.3.0 | Apache-2.0 | No |
| Compose BOM | 2026.09.00 | Apache-2.0 | No (Android) |
| ktor | 3.6.0 | Apache-2.0 | No (not used) |
| OkHttp / Okio | 5.5.0 / 3.18.2 | Apache-2.0 | No (not used) |
| Gson | 2.14.0 | Apache-2.0 | n/a |
| Room / SQLCipher | 2.8.5 / 4.19.0 | Apache-2.0 / BSD-style | No |
| MMKV | 1.3.14 | BSD-3-Clause | n/a |
| commons-compress / xz / zip4j | 1.28.0 / 1.12 / 2.11.6 | Apache-2.0 / 0BSD / Apache-2.0 | n/a |
| ByteHook | 1.0.10 | MIT | No (Android PLT hooking) |
| NG-GL4ES (AAR) | prebuilt | MIT | No (Android build) |
| SDL3 / sdl2-compat (AAR) | prebuilt | Zlib | No (Android build) |
| LWJGL natives (AAR) | 3.3.3 / 3.4.1 | BSD-3-Clause | No (Android build) |
| proxy-client-android | 0.0.5 | LGPL-3.0 | No |
| sora-editor | 0.24.6 | LGPL-2.1 | No |

Every Android binary in upstream is unusable on iOS as shipped. Each would need an iOS build from source, where the source allows it.
