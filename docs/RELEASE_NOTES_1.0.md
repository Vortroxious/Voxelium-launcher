# Voxelium 1.0

Voxelium now runs **Forge and NeoForge**, alongside Fabric and Quilt.

> Not affiliated with Mojang, Microsoft, Modrinth, the Forge or NeoForge projects. You need a Minecraft: Java Edition account. JIT is required: start Voxelium from **StikDebug**. See the [install guide](INSTALL.md).

## New
- **Forge and NeoForge.** Pick them in the install sheet, like Fabric:
  - Forge is offered for Minecraft 1.17 and newer, with its recommended build preselected.
  - NeoForge is offered for 1.20.2 and newer.
  - The **first launch** takes a minute or two longer: Voxelium finishes setting up the loader inside the game (it patches Minecraft once), then the game starts in the same run. You don't need to restart the app.
- **Forge and NeoForge modpacks** from Modrinth install like Fabric packs (browse or import a `.mrpack`).
- **Mods match the loader:**
  - the Modrinth browser and update checks only offer builds for your version's loader;
  - importing a mod made for another loader (a Fabric mod into NeoForge, for example) is refused, with a hint to use Browse.
- **Delete versions:** installed version → **Play → Delete version…**. For a modded version or modpack, this also deletes its worlds, mods and settings, so you're asked first (share a world from Worlds… to keep it). Vanilla worlds are shared and stay. A Minecraft version that a loader or modpack builds on can only be deleted after them.
- **Shaders on Forge:** Forge versions are offered **Oculus** (with Embeddium) instead of Iris. The render-distance warning and the "Shaders in game" switch work with Oculus too.

## Tested
On an iPhone 15 Pro Max with iOS 27.0:

| Version | Loader | Result |
|---|---|---|
| Minecraft 1.21.1 | NeoForge 21.1.264 | Set up in 18 s (first launch), joined a world; checked again on the 1.0 build |
| Minecraft 1.20.1 | Forge 47.4.10 | Set up in 20 s (first launch), joined a world. On the 1.0 build: Oculus + Embeddium + BSL, the render-distance warning shown, about 2.5 GB of memory |
| Minecraft 1.21.11 | Fabric 0.19.5 | Iris + BSL still work on the 1.0 build |

- NeoForge 1.21.11 and Forge 1.21.11 reached the title screen on a Mac with the same setup code, but are not yet tested on the phone.
- Forge and NeoForge modpacks are not yet tested on the phone.

## Updating
Install over 0.1.1 (or 0.1.0) with Sideloadly using the **same Apple ID**, so iOS keeps the app's data: your versions, mods and worlds stay. Coming from 0.1.0, the data folder moves into Files on the first start, as described in the [0.1.1 notes](RELEASE_NOTES_0.1.1.md).

## Known limits
- **Not supported:**
  - Minecraft 26.2 and newer;
  - 1.12.2 and older;
  - Forge before 1.17;
  - shader packs that need compute shaders (e.g. Photon).
- **Memory:** iOS limits the app's memory (about 3.4 GB on the test phone). Big modpacks, and shaders at a high render distance, can close the game; keep the render distance at 8–10 with shaders.
- Tested on one device. iPad is not tested; Quilt is not tried on a device.
- Apps signed with a free Apple ID must be refreshed every 7 days.

## Files
- `Voxelium-1.0-unsigned.ipa`: install it with Sideloadly ([step by step](../README.md#installing-on-your-iphone)). SHA-256: `ee9564c2ecc0ffea9eab5f12724adf428bde800183bf41b1830f2a8b104c416f` (build 202610211631, 184,845,978 bytes)
- `THIRD_PARTY_NOTICES.txt`: licences of the bundled components (unchanged). Forge, NeoForge and their tools are downloaded from their own servers when you install them; they are not bundled.
- Source code: this tag, including `JavaRuntime/voxelium-boot` (the small Java program that sets Forge/NeoForge up on the first launch).

## Thanks
ZalithLauncher2, Amethyst-iOS and PojavLauncher (prior art), AngelAuraMC (iOS OpenJDK and LWJGL builds), the MobileGlues, ANGLE, gl4es, LWJGL, OpenAL Soft and FreeType projects, the Forge and NeoForge projects, and Modrinth.
