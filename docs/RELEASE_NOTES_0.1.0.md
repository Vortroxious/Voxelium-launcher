# Voxelium 0.1.0 (draft)

The first public release of Voxelium, a launcher that runs **Minecraft: Java Edition on iPhone**. It is unofficial and free software (GPL-3.0).

> Not affiliated with Mojang, Microsoft or Modrinth. You need a Minecraft: Java Edition account. Voxelium downloads the game from Mojang for your account. JIT is required: start Voxelium from **StikDebug**. See the [install guide](INSTALL.md).

## What works
- **Minecraft 1.13 – 26.1.2**, on bundled Java 8, 17, 21 and 25. OpenGL through MobileGlues or gl4es on ANGLE (Metal).
- **Microsoft sign-in** (tokens kept in the iOS Keychain).
- **Fabric and Quilt**: install any loader build for a version; each modded version gets its own game folder.
- **Mod manager**: add, switch on/off and remove mods, resource packs and shader packs; one-tap **updates** from Modrinth (releases are never offered a beta).
- **Modrinth browser**: search mods, resource packs and shader packs for your version and loader, and install them with their required dependencies (SHA-1 verified).
- **Modpacks**: install Modrinth Fabric/Quilt modpacks from the browser or a `.mrpack` file.
- **Shaders (Iris)**: BSL and MakeUp Ultra Fast render correctly. A warning suggests render distance 8–10 with shaders, and an in-game gauge shows memory against iOS's limit.
- **Touch controls**: joystick, buttons, hotbar, a custom layout editor (Controls tab), and pause-and-save when you leave the app.

## Known limits
- Tested on one device: iPhone 15 Pro Max, iOS 27.0, StikDebug 3.1.14. iPad is not tested. Quilt is built but not tried on a device.
- Not yet supported: Minecraft 26.2+, 1.12.2 and older, Forge/NeoForge (planned for the next update), and shader packs that need compute shaders (e.g. Photon).
- iOS limits the app's memory (about 3.4 GB on the test phone): very large modpacks, and shaders at high render distance, can close the game.
- Apps signed with a free Apple ID must be refreshed every 7 days.

## Files
- `Voxelium-0.1.0-unsigned.ipa`: install it with Sideloadly. Step by step, including StikDebug, the pairing file and LocalDevVPN, in the [README](../README.md#installing-on-your-iphone). SHA-256: `d7e189b24c2aa7a4ee1872e5a6f98513a8767117064041892769a074801b8255` (build 202610180753, from commit `a05b565`, 184,714,117 bytes)
- `THIRD_PARTY_NOTICES.txt`: licences of the bundled components.
- Source code: this tag, including patches and build scripts for every bundled library.

## Thanks
ZalithLauncher2, Amethyst-iOS and PojavLauncher (prior art), AngelAuraMC (iOS OpenJDK and LWJGL builds), the MobileGlues, ANGLE, gl4es, LWJGL, OpenAL Soft and FreeType projects, and Modrinth.
