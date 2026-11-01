# Voxelium 2.4

**Browse CurseForge, and know when Voxelium updates.**

> Not affiliated with Mojang, Microsoft, Modrinth, CurseForge, the Forge or NeoForge projects. You need a Minecraft: Java Edition account, iOS 17.4 or later, LocalDevVPN and a pairing file. See the [install guide](../README.md#installing-on-your-iphone).

## New
- **Browse CurseForge.** In a version's **Mods & packs**, tap **+** → **Browse CurseForge**, below Browse Modrinth.
  - Search and install mods, resource packs and shader packs for that version's Minecraft version and loader. Required mods come along, as with Modrinth.
  - No API key needed: Voxelium has one built in.
  - Some authors only allow downloads on CurseForge's website. For their files, Voxelium shows an **Open on CurseForge** link: download the file there and add it with **+ → Import from Files**.
- **Update checks.**
  - Once a day, Voxelium asks GitHub for the latest release. When there's a newer one, a row at the top of the Versions tab links to it.
  - **Diagnostics → Updates** has **Check for updates** and a switch to turn the daily check off.
  - Nothing about you is sent, and nothing is downloaded or installed by itself: install the new IPA with Sideloadly, as always.

## Fixed
- **Taps stopped working in Minecraft's menus** after F11 on a Bluetooth keyboard (or the Fullscreen option) turned on Minecraft's fullscreen. Voxelium now turns fullscreen off before each start; on an iPhone the game always fills the screen anyway.
- **Forge and NeoForge versions failed their first start** when Voxelium had been reinstalled (updated) between installing the version and playing it. Their one-time setup now follows the app's data folder.

## Tested
On an iPhone 15 Pro Max with iOS 27.0, with test builds of this release:
- CurseForge search with the built-in key.
- The update notice: a build reporting version 2.2 showed "Voxelium 2.3 is available".
- Fabric 1.21.11 with fullscreen on in its options: Voxelium turned it off, and taps worked again.
- CurseForge installs into NeoForge 1.21.11: Sound Physics Remastered and Architectury API. NeoForge 1.21.11, installed before a reinstall, then set itself up, joined a world and quit cleanly.

Everything else is unchanged from [2.3](RELEASE_NOTES_2.3.md).

## Updating
Install over 2.3 with Sideloadly using the **same Apple ID**. Your versions, mods, worlds and pairing file stay.

## Known limits
- Mod update checks still use Modrinth only. Files installed from CurseForge are checked only if Modrinth has the same file.
- No CurseForge modpacks yet.
- Game controllers and mice aren't supported. A Bluetooth keyboard works for typing and keys.
