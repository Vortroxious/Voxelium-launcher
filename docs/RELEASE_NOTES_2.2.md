# Voxelium 2.2

**Open Voxelium like any app.** You no longer have to start it from StikDebug: Voxelium asks StikDebug for JIT when you start a game, the way Amethyst does.

> Not affiliated with Mojang, Microsoft, Modrinth, the Forge or NeoForge projects. You need a Minecraft: Java Edition account, and **StikDebug** (with LocalDevVPN and a pairing file) to turn on JIT. See the [install guide](INSTALL.md).

## New
- **JIT from StikDebug, automatically.**
  1. Open Voxelium from the Home Screen and tap **Play**.
  2. If JIT is off, Voxelium opens StikDebug, which asks you to confirm.
  3. StikDebug turns JIT on for the running Voxelium and switches back, and the game starts. In testing this took about 4 seconds.
  - **iOS 26:** on iPhones that need it, Voxelium sends StikDebug the JIT script (`UniversalJIT26.js`) itself, so you no longer assign a script in StikDebug.
  - **The old way:** starting Voxelium from StikDebug still works.
- **Quitting closes smoothly.** When you quit Minecraft, Voxelium now goes back to the Home Screen with the normal iOS close animation. Before, it disappeared instantly, like a crash. Your world is saved before this happens, as before.

## Tested
On an iPhone 15 Pro Max with iOS 27.0:
- **Hand-off:** Voxelium opened from the Home Screen; Play → StikDebug → JIT on → Fabric 1.21.11 started and joined a world.
- **Close:** quitting closed the app to the Home Screen.

Everything else is unchanged from [2.1](RELEASE_NOTES_2.1.md).

## Updating
Install over 2.1 with Sideloadly using the **same Apple ID**. Your versions, mods and worlds stay. You can remove the script you assigned to Voxelium in StikDebug, but leaving it does no harm.

## Known limits
- StikDebug still has to be installed and connected: LocalDevVPN on, pairing file imported, and on mobile data, Airplane Mode on while you tap Play.
- 26.3 runs on Vulkan only (iOS 26+). Not supported: 1.12.2 and older, and Forge before 1.17.
- iOS limits the app's memory (about 3.4 GB on the test phone). Tested on one iPhone. Apps signed with a free Apple ID must be refreshed every 7 days.

## Files
- `Voxelium-2.2-unsigned.ipa`: install it with Sideloadly ([step by step](../README.md#installing-on-your-iphone)). SHA-256: `781fb54b0689463fbb906fd4b35fbd51779fb207182c1f9e9999a39281be2cc1` (build 202610241422, 213,475,257 bytes)
- `THIRD_PARTY_NOTICES.txt`: licences of the bundled components (unchanged from 2.1).
- Source code: this tag.

## Thanks
Amethyst-iOS for the StikDebug hand-off and the smooth exit (both GPL-3.0), and StikDebug for its `enable-jit` link.
