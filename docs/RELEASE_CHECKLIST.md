# Release checklist (Voxelium 0.1.0)

Status as of 2026-10-18. ✅ done, ⏳ needs doing, 👤 needs the maintainer (accounts, publishing).

## Code and builds
- ✅ All features in the README status table verified on an iPhone 15 Pro Max (iOS 27.0), except Quilt (built, not run on device).
- ✅ `swift test`: 97 tests pass.
- ✅ Normal (non-diagnostic) MobileGlues in the IPA. Check: `strings …/libmobileglues.dylib | grep -c MG-GLERR` is 0.
- ✅ Final IPA from a clean tree (2026-10-18): `build/ipa/Voxelium-0.1.0-unsigned.ipa`, build 202610180725 from commit `8e592a6`, 183,355,846 bytes, SHA-256 `ab230812414aad8376e809332dde1ba0f76e5db991365dcdb53359e94f975280`. Checked: no diagnostics in MobileGlues, patch 0014 present, notices identical to the repo, all four Java runtimes, no signing files.
- ⏳ One last device pass with that exact IPA: launch vanilla 1.21.11, Fabric 1.21.11 with Sodium and Iris (BSL), a modpack, and 1.16.5 (gl4es).

## Licences (GPL-3.0 and bundled components)
- ✅ `LICENSE` (GPL-3.0), `NOTICE.md` (summary table), `THIRD_PARTY_NOTICES.txt` (full texts from the built sources, also in the app under Diagnostics → About Voxelium & licences).
- ✅ LGPL parts (MobileGlues, OpenAL Soft) are dynamically linked. Their sources, our patches (`patches/`) and build scripts are in the repository, so users can rebuild and replace them.
- ✅ FastSTL (no licence) removed; ANGLE's linked third-party code (abseil, Perfetto, zlib, libc++, xxHash) identified from its symbols and included.
- ✅ No Minecraft files, signing certificates, provisioning profiles, tokens or keys in the repository or the IPA (scanned 2026-10-18; the only `refresh_token` strings are fake test values).
- 👤 **Source for the exact release:** GPL requires it. Publish the repository and tag the release commit `v0.1.0`; GitHub's source archives for the tag cover it.

## Accounts and risks
- 👤 **Microsoft sign-in** uses the client ID Amethyst uses (`00000000402b5328`, Microsoft's Minecraft launcher ID), chosen by the maintainer. It works today; Microsoft could restrict it at any time. `docs/MICROSOFT_SIGN_IN.md` explains how to switch to your own approved Azure app ID instead.
- ✅ Tokens are stored only in the iOS Keychain; no passwords are handled.
- 👤 Modrinth asks API clients for an identifying User-Agent (sent: `Voxelium/0.1.0 (iOS Minecraft launcher)`). Consider adding a contact URL once the repository exists.

## Publishing
- 👤 Replace `VOXELIUM_RELEASES_URL` in the README's install table with the release page link.
- 👤 Create the GitHub repository (owner and name are the maintainer's choice), add it as `origin`, push `main`, and push the `v0.1.0` tag.
- 👤 Create the GitHub release from the tag with:
  - `Voxelium-0.1.0-unsigned.ipa`
  - `THIRD_PARTY_NOTICES.txt`
  - the notes in [RELEASE_NOTES_0.1.0.md](RELEASE_NOTES_0.1.0.md), with the IPA's SHA-256 filled in.
- 👤 Video and announcement. Say clearly: unofficial, not affiliated with Mojang or Microsoft, needs a Java Edition account, needs StikDebug for JIT, tested on one device.
