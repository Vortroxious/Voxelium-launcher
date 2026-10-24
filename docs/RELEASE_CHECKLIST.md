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
- ✅ `main` and the `v0.1.0` tag pushed by the maintainer (2026-10-18), after all commits were rewritten to the author Vortroxious with a GitHub no-reply email.
- ✅ GitHub Release **v0.1.0** published 2026-10-18 08:29 UTC: https://github.com/Vortroxious/Voxelium-launcher/releases/tag/v0.1.0 (not a draft or pre-release). Assets checked against GitHub's own digests: `Voxelium-0.1.0-unsigned.ipa` 184,714,117 bytes, SHA-256 `d7e189b2…8255` (the tested build); `THIRD_PARTY_NOTICES.txt` 256,369 bytes, SHA-256 `309c9c67…62bf`, identical to the repository's. The README's `releases/latest` link resolves to it.
- ✅ Release description added by the maintainer (checked 2026-10-21 via the GitHub API).
- 👤 Video and announcement. Say clearly: unofficial, not affiliated with Mojang or Microsoft, needs a Java Edition account, needs StikDebug for JIT, tested on one device.

# Release checklist (Voxelium 1.0)

Status as of 2026-10-21.
- ✅ Version 1.0 (`MARKETING_VERSION`, `LaunchPlanner.launcherVersion`, Modrinth User-Agent `Voxelium/1.0 (iOS Minecraft launcher; github.com/Vortroxious/Voxelium-launcher)`).
- ✅ Release notes: [RELEASE_NOTES_1.0.md](RELEASE_NOTES_1.0.md).
- ✅ Device pass on the final 1.0 IPA (build 202610211631, SHA-256 `ee9564c2…416f`, confirmed installed with `devicectl`, 2026-10-21 16:37–16:40Z): Fabric 1.21.11 + Iris/BSL, NeoForge 1.21.1 and Forge 1.20.1 + Oculus/BSL each joined a world and quit cleanly; the shader warning appeared on Forge; Delete version removed two modpacks.
- ⏳ Commit, then tag `v1.0`.
- 👤 Push `main` and `v1.0`. Create the GitHub Release **v1.0** with `Voxelium-1.0-unsigned.ipa` and `THIRD_PARTY_NOTICES.txt`, and paste the release notes (without their first line).
- ✅ Licences: nothing new is bundled except `voxelium-boot.jar` (our own GPL-3.0 code). Forge, NeoForge and their installer tools are downloaded from their own Maven servers at install time, not shipped.

# Release checklist (Voxelium 2.0)

Status as of 2026-10-24.
- ✅ Merged the 26.3 / Vulkan work into `main` (`e0e2aae`); version 2.0, licences (SDL, Mesa) and notes committed as `8369ada`, tagged `v2.0`.
- ✅ Device pass on the release IPA (build 202610240359): Fabric 1.21.11 on MobileGlues and on Vulkan (Zink), Fabric 26.3 with Sodium + Iris on Vulkan. See the engineering log.
- ✅ Pushed by the maintainer: GitHub's `main` and `v2.0` → `8369ada`.
- ✅ GitHub Release **v2.0** published 2026-10-24 04:24Z, latest; `releases/latest` resolves to it. Assets, checked against GitHub's digests at 04:29Z:
  - `Voxelium-2.0-unsigned.ipa`: 213,461,120 bytes, `e1d6f28d…bfe4` (the tested build);
  - `Voxelium-2.0-unsigned.ipa.sha256`: 92 bytes, `5643a429…43e3`;
  - `THIRD_PARTY_NOTICES.txt`: 401,252 bytes, `2656920b…0d74`, identical to the repository's. It was first attached as the 1.0 file and replaced by the maintainer.
- The description was pasted as HTML (as for 1.0). The maintainer reports it renders correctly.

# Release checklist (Voxelium 2.1)

Status as of 2026-10-24.
- ✅ Minecraft 26.2 fix (MobileGlues patch 0015) merged into `main` (`0fa9679`); version 2.1, release notes [RELEASE_NOTES_2.1.md](RELEASE_NOTES_2.1.md).
- ✅ Device pass on the release IPA (build 202610241301, SHA-256 `d04f01c2…d616`): Fabric 26.2 on MobileGlues and on Vulkan. Regression on the same code (build 202610241249): Fabric 26.1.2, Fabric 1.21.11 and NeoForge 1.21.1 on MobileGlues.
- ✅ Committed and tagged `v2.1`.
- 👤 Push `main` and `v2.1`. Create the GitHub Release **v2.1** with `build/ipa/Voxelium-2.1-unsigned.ipa`, `Voxelium-2.1-unsigned.ipa.sha256` and `build/ipa/THIRD_PARTY_NOTICES.txt` (401,252 bytes; check it is not the 0.24 MB 1.0 file), and paste the release notes.

# Release checklist (Voxelium 2.2)

Status as of 2026-10-24.
- ✅ StikDebug JIT hand-off and smooth close merged into `main` (`7b32063`); version 2.2, release notes [RELEASE_NOTES_2.2.md](RELEASE_NOTES_2.2.md).
- ✅ Device pass on the release IPA (build 202610241422, SHA-256 `781fb54b…2cc1`): opened from the Home Screen, JIT from StikDebug in 4 s, Fabric 1.21.11 started, and quitting closed the app to the Home Screen.
- ✅ Committed and tagged `v2.2`.
- 👤 Push `main` and `v2.2`. Create the GitHub Release **v2.2** with `build/ipa/Voxelium-2.2-unsigned.ipa`, its `.sha256` and `build/ipa/THIRD_PARTY_NOTICES.txt` (0.38 MB), and paste the release notes.
