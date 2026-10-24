# Installing and playing Voxelium

Voxelium runs Minecraft: Java Edition on iPhone. Java needs JIT, which iOS only allows while a debugger is attached. You open Voxelium from the Home Screen, and when you start a game it asks **StikDebug** to turn JIT on: StikDebug opens, asks you to confirm, and switches back. Starting Voxelium from StikDebug, as in earlier versions, also works.

Tested on an iPhone 15 Pro Max with iOS 27.0 and StikDebug 3.1.14. Other devices and iOS versions are not tested yet.

## Installing
Follow the step-by-step guide in the README: **[Installing on your iPhone](../README.md#installing-on-your-iphone)**. It covers what to download (Sideloadly, idevice_pair, StikDebug, LocalDevVPN, optionally GetMoreRam), Developer Mode, the pairing file, assigning `universal.js`, and starting Voxelium from StikDebug, including the Airplane Mode step on mobile data.

You also need a Minecraft: Java Edition account (Microsoft account), and about 2–4 GB of free space: the app is about 0.5 GB, plus Minecraft versions, mods and worlds. Voxelium does not include Minecraft; it downloads the game from Mojang for your own account.

## Sign in and play
1. **Account tab:** Sign in with Microsoft. Copy the code and open the sign-in page. Tokens are kept in the iOS Keychain; passwords never reach Voxelium.
2. **Versions tab:** Install a version (1.13 – 26.2, or 26.3 on iOS 26+). For mods, pick Fabric, Quilt, Forge or NeoForge in the install sheet, or tap **Modpacks** to install a whole pack.
3. Under **Installed**, tap **Play → Launch Minecraft**.

## Mods, packs and shaders
- Installed version → **Play → Mods & packs…**. Tap **+** to browse Modrinth or import files. Switch mods on and off, and update them when Voxelium finds newer versions.
- Shader packs need **Iris** (offered when missing). BSL and MakeUp Ultra Fast work. Packs that need compute shaders, such as Photon, cannot run on iOS's OpenGL ES 3.0.
- **Memory:** keep the render distance at **8–10** with shaders. Higher values can use more memory than iOS allows, and the game closes. The gauge under **More** in game turns orange, then red, as memory fills.

## Bringing your worlds
Voxelium's data folder is in the Files app: **Files → On My iPhone → Voxelium**.

| Folder | What's in it |
|---|---|
| `minecraft/` | Vanilla versions' game folder: `saves/`, `resourcepacks/`, `shaderpacks/`, `options.txt` |
| `minecraft/versions/<name>/` | Each modded version (Fabric, Quilt, Forge, NeoForge) or modpack has its own: `saves/`, `mods/`, `config/`, `options.txt` … |
| `logs/` | `launcher.log` and `jvm.log`, for bug reports |
| `config/`, `controls/` | Launcher settings and on-screen control layouts |

Two ways to add a world (a Java Edition world folder holds a `level.dat`):
- **In Voxelium:** Installed version → **Play → Worlds…** → **+**, then pick a world folder or a `.zip`. A world inside a subfolder of the zip is found too. If the name is taken, the copy becomes "World (2)". Swipe left on a world to **Share** it as a `.zip` (to save it in Files or AirDrop it) or to **Delete** it.
- **In Files:** copy the world folder into `minecraft/saves`, or into `minecraft/versions/<name>/saves` for a modded version or modpack.

**Deleting a version** (Play → Delete version…) removes a modded version's worlds and mods with it; share worlds you want to keep first. Vanilla worlds in `minecraft/saves` are not touched.

Close Minecraft before copying worlds in Files: a world copied while the game is running can be damaged. Bedrock worlds (`.mcworld`) can't be opened by Java Edition.

Your Microsoft sign-in is kept in the iOS Keychain, not in this folder.

Updating from 0.1.0: the first start moves everything from the old hidden folder into this one. Nothing is overwritten; the launcher log lists what moved.

## Known limits
- 26.3 runs on Vulkan only, which needs iOS 26 or later. 26.2 runs on both renderers. Versions 1.12.2 and older are not supported.
- **Renderers:** on 1.17 – 26.1.2, Play offers MobileGlues (as in 1.0) or Vulkan (iOS 26+). Each renderer can start once per app launch; close and reopen Voxelium to switch.
- Forge and NeoForge are new: NeoForge for 1.21.1 and Forge for 1.20.1 are tested on an iPhone; other versions not yet. Their first launch takes a minute or two longer, because Voxelium finishes setting them up then (it patches Minecraft once). Forge is offered for Minecraft 1.17 and newer, NeoForge for 1.20.2 and newer.
- Very large modpacks (hundreds of mods) do not fit in iPhone memory.
- If StikDebug doesn't bring you back, or the game doesn't start, close Voxelium, check LocalDevVPN is on, open Voxelium again and tap Play.

## When something goes wrong
- **Logs tab:** the launcher log. `logs/jvm.log` (Files → On My iPhone → Voxelium → logs) holds the game's output.
- Report problems with your device, iOS version, Voxelium version (Diagnostics → About) and both logs.
