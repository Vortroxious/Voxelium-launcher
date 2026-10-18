# Release checklist (Voxelium 0.1.0)

Status as of 2026-10-18. ✅ done, ⏳ needs doing, 👤 needs the maintainer (accounts, publishing).

## Code and builds
- ✅ All features in the README status table verified on an iPhone 15 Pro Max (iOS 27.0), except Quilt (built, not run on device).
- ✅ `swift test`: 97 tests pass.
- ✅ Normal (non-diagnostic) MobileGlues in the IPA. Check: `strings …/libmobileglues.dylib | grep -c MG-GLERR` is 0.
- ✅ Final IPA from a clean tree (2026-10-18): `build/ipa/Voxelium-0.1.0-unsigned.ipa`, build 202610180753 from commit `a05b565` (with the app icon), 184,714,117 bytes, SHA-256 `d7e189b24c2aa7a4ee1872e5a6f98513a8767117064041892769a074801b8255`. Checked: no diagnostics in MobileGlues, patch 0014 present, notices identical to the repo, app icon, all four Java runtimes, no signing files.
- ✅ Device pass with that exact IPA (installed build confirmed as 202610180753 with `devicectl`, 2026-10-18 07:58–08:01Z): vanilla 1.21.11 (render distance 16, 1.46 GB), Fabric 1.21.11 with Sodium + Iris + BSL (55 mods, render distance 8, 2.16 GB) and 1.16.5 on Java 8 + gl4es (1.77 GB) each joined a world and quit cleanly.
- ✅ A modpack on that IPA (08:03Z): Fabulously Optimized 13.6.0 on 26.1.2 (Java 25, LWJGL 3.4.1, Sodium 0.9 + Iris), 149 mods, joined a world at view distance 8, 1.85 GB, quit cleanly.

## Licences (GPL-3.0 and bundled components)
- ✅ `LICENSE` (GPL-3.0), `NOTICE.md` (summary table), `THIRD_PARTY_NOTICES.txt` (full texts from the built sources, also in the app under Diagnostics → About Voxelium & licences).
- ✅ LGPL parts (MobileGlues, OpenAL Soft) are dynamically linked. Their sources, our patches (`patches/`) and build scripts are in the repository, so users can rebuild and replace them.
- ✅ FastSTL (no licence) removed; ANGLE's linked third-party code (abseil, Perfetto, zlib, libc++, xxHash) identified from its symbols and included.
- ✅ No Minecraft files, signing certificates, provisioning profiles, tokens or keys in the repository or the IPA (scanned 2026-10-18; the only `refresh_token` strings are fake test values).
- 👤 **Source for the exact release:** GPL requires it. Publish the repository and tag the release commit `v0.1.0`; GitHub's source archives for the tag cover it.

## Accounts and risks
- 👤 **Microsoft sign-in** uses the client ID Amethyst uses (`00000000402b5328`, Microsoft's Minecraft launcher ID), chosen by the maintainer. It works today; Microsoft could restrict it at any time. `docs/MICROSOFT_SIGN_IN.md` explains how to switch to your own approved Azure app ID instead.
- ✅ Tokens are stored only in the iOS Keychain; no passwords are handled.
- 👤 Modrinth asks API clients for an identifying User-Agent (sent: `Voxelium/0.1.0 (iOS Minecraft launcher)`). Consider adding the repository URL to it in the next version (it is compiled into the app).

## Publishing
- ✅ README download link points to https://github.com/Vortroxious/Voxelium-launcher/releases/latest.
- ✅ Repository created by the maintainer: https://github.com/Vortroxious/Voxelium-launcher (public, empty on 2026-10-18); added as `origin`, `v0.1.0` tagged locally.
- 👤 Push `main` and the `v0.1.0` tag (needs the maintainer's go-ahead and GitHub credentials).
- 👤 Create the GitHub release from the tag with:
  - `Voxelium-0.1.0-unsigned.ipa`
  - `THIRD_PARTY_NOTICES.txt`
  - the notes in [RELEASE_NOTES_0.1.0.md](RELEASE_NOTES_0.1.0.md), with the IPA's SHA-256 filled in.
- 👤 Video and announcement. Say clearly: unofficial, not affiliated with Mojang or Microsoft, needs a Java Edition account, needs StikDebug for JIT, tested on one device.
