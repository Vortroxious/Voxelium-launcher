# Voxelium 0.1.1

Get your worlds in and out of Voxelium: the game folder now shows in the Files app, and a new **Worlds** screen imports and shares worlds.

> Not affiliated with Mojang, Microsoft or Modrinth. You need a Minecraft: Java Edition account. JIT is required: start Voxelium from **StikDebug**. See the [install guide](INSTALL.md).

## New
- **Voxelium in the Files app:** **Files → On My iPhone → Voxelium** shows `minecraft/` (worlds in `saves/`, resource packs, shader packs, `options.txt`), `minecraft/versions/<name>/` for each Fabric/Quilt version or modpack (its own `saves/`, `mods/`, `config/`), and `logs/` for bug reports. Copy worlds, mods and packs in or out directly, with Minecraft closed.
- **Worlds screen:** Installed version → **Play → Worlds…**. Import a Java world folder or `.zip` (a world inside a subfolder of the zip is found too; a clashing name becomes "World (2)"), swipe left to **Share** a world as a `.zip` or **Delete** it. Bedrock worlds (`.mcworld`) are refused with an explanation.
- More in [Bringing your worlds](INSTALL.md#bringing-your-worlds).

## Updating from 0.1.0
Install over 0.1.0 with Sideloadly using the **same Apple ID**, so iOS keeps the app's data. On the first start, Voxelium moves everything from its old hidden folder into the one Files shows. Nothing is overwritten, and the launcher log (Logs tab) lists what moved. Your Microsoft sign-in stays in the iOS Keychain and is not in the Files folder.

Tested on an iPhone 15 Pro Max with iOS 27.0 (build 202610181331, the same code before the version number changed): the 0.1.0 data moved over, and a world imported through Worlds… was played in Fabric 1.21.11 with BSL shaders.

## Known limits
Unchanged from 0.1.0: Minecraft 26.2+, 1.12.2 and older, and Forge/NeoForge are not supported yet; iOS memory limits apply to large modpacks and shaders at high render distance; apps signed with a free Apple ID must be refreshed every 7 days.

## Files
- `Voxelium-0.1.1-unsigned.ipa`: install it with Sideloadly ([step by step](../README.md#installing-on-your-iphone)). SHA-256: `e93a716e5c21898e09cae6fea113c235435ff0506a097c8c058179d19054e0f1` (build 202610181352, from commit `a40c0a2`, 184,786,307 bytes)
- `THIRD_PARTY_NOTICES.txt`: licences of the bundled components (unchanged).
- Source code: this tag.
