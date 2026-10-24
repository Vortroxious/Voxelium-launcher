# Voxelium 2.1

Voxelium 2.1 runs **Minecraft 26.2**. With it, every version from 1.13 to 26.3 is supported.

> Not affiliated with Mojang, Microsoft, Modrinth, the Forge or NeoForge projects. You need a Minecraft: Java Edition account. JIT is required: start Voxelium from **StikDebug**. See the [install guide](INSTALL.md).

## New
- **Minecraft 26.2 works.** It used to show only a red screen and then black.
  - **Cause:** 26.2 draws everything with an OpenGL call (`glDrawElementsInstancedBaseVertex`) that the iPhone's OpenGL ES 3.0 layer rejects under its standard name.
  - **Fix:** Voxelium now uses the extension version of that call, as it already did for the one older versions use.
  - **Renderers:** 26.2 offers both, like 26.1.2: **Play with MobileGlues** (any supported iOS) and **Play with Vulkan** (iOS 26+). MobileGlues uses less memory for 26.2.
- The same fix applies to every 1.17+ version on MobileGlues, wherever a game or mod uses those draw calls.

## Tested
On an iPhone 15 Pro Max with iOS 27.0 (Fabric 26.2 on both renderers with this IPA, build 202610241301):

| Version | Renderer | Result |
|---|---|---|
| 26.2 (vanilla and Fabric) | MobileGlues | Joined a world, quit cleanly; peak memory 2.2–2.4 GB |
| 26.2 (vanilla and Fabric) | Vulkan (Zink) | Joined a world, quit cleanly; peak 2.5–3.0 GB |
| Fabric 26.1.2 | MobileGlues | Joined a world, quit cleanly; 2.4 GB |
| Fabric 1.21.11 | MobileGlues | Joined a world, quit cleanly; 2.3 GB |
| NeoForge 1.21.1 | MobileGlues | Joined a world, quit cleanly; 1.7 GB |

Everything else is unchanged from [2.0](RELEASE_NOTES_2.0.md).

## Updating
Install over 2.0 with Sideloadly using the **same Apple ID**. Your versions, mods and worlds stay.

## Known limits
- **26.3 runs on Vulkan only,** which needs iOS 26 or later.
- **Not supported:** 1.12.2 and older, Forge before 1.17, and shader packs that need compute or geometry shaders on the iPhone's GPU (e.g. Photon).
- **Memory:** iOS limits the app's memory (about 3.4 GB on the test phone). Vulkan uses more than MobileGlues, so if the game closes, use MobileGlues or lower the render distance.
- **One phone:** tested on a single iPhone; iPad is not tested.
- **Free Apple ID:** apps signed with one must be refreshed every 7 days.

## Files
- `Voxelium-2.1-unsigned.ipa`: install it with Sideloadly ([step by step](../README.md#installing-on-your-iphone)). SHA-256: `d04f01c215210890c4f9490a455e1b554e52acd1ba854465433755e9914da616` (build 202610241301, 213,459,733 bytes)
- `THIRD_PARTY_NOTICES.txt`: licences of the bundled components (MobileGlues now with Voxelium patches 0001–0015).
- Source code: this tag, including `patches/mobileglues/0015-es30-instanced-and-range-base-vertex-extensions.patch`.
