# Voxelium 2.5

**A new look: the same interface as Voxelium for Android.**

> Not affiliated with Mojang, Microsoft, Modrinth, CurseForge, the Forge or NeoForge projects. You need a Minecraft: Java Edition account, iOS 17.4 or later, LocalDevVPN and a pairing file. See the [install guide](../README.md#installing-on-your-iphone).

## New
- **A new interface**, made for iPhone in portrait. iPad works in every orientation, and the game still plays in landscape.
  - **Tabs:** Play, Install, Accounts, Controls and Settings. JIT and Diagnostics are now inside Settings.
  - **Play:** your last played version on a big card with Play, and your other versions below it.
  - **Install:** search Minecraft's versions, then pick a mod loader and build in one sheet. Modpacks open from the top of the page.
  - **Version page:** tap **…** on a version for its mods, resource packs, shader packs, worlds and settings.
  - **Controls:** edit your layout in portrait on a small preview, or use the full-screen editor. You can now import and share layout files.
  - **Logs** (Settings → Logs): filters and Share. If Minecraft stops with an error, Voxelium shows why and lets you share the logs.
- **Accent colour.** Settings → Appearance has 25 colours, from red and orange to blue, purple, white and black. Each has a shade for light mode and one for dark mode.

## Fixed
- Fabric and Quilt loader builds are listed newest first.
- Installing the same modpack for a second loader no longer replaces the first: it gets its own name.
- A required mod you already have (from the other site, or imported from Files) isn't downloaded a second time. Two copies of one mod stopped Fabric from starting.

## Tested
TBD after the device pass on the release IPA.

Everything else is unchanged from [2.4](RELEASE_NOTES_2.4.md).

## Updating
Install over 2.4 with Sideloadly using the **same Apple ID**. Your versions, mods, worlds, controls and pairing file stay.

## Known limits
- Mod update checks still use Modrinth only. Files installed from CurseForge are checked only if Modrinth has the same file.
- No CurseForge modpacks yet.
- Game controllers and mice aren't supported. A Bluetooth keyboard works for typing and keys.
