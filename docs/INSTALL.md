# Installing and playing Voxelium

Voxelium runs Minecraft: Java Edition on iPhone. Java needs JIT, which iOS only allows while a debugger is attached, so you start Voxelium through **StikDebug** each time.

Tested on an iPhone 15 Pro Max with iOS 27.0 and StikDebug 3.1.14. Other devices and iOS versions are not tested yet.

## What you need
- An iPhone. The A17 Pro used for testing has 8 GB of RAM; iOS lets Voxelium use about 3.4 GB of it. iPads may work, since the app installs on them, but none has been tested yet.
- A computer, once, to sideload apps and to set up StikDebug's pairing file.
- A Minecraft: Java Edition account (Microsoft account). Voxelium does not include Minecraft; it downloads the game from Mojang for your own account.
- About 2–4 GB of free space: the app is about 0.5 GB, plus Minecraft versions, mods and worlds.

## 1. Install Voxelium
1. Download `Voxelium-<version>-unsigned.ipa` from the release page.
2. Sign and install it with a free Apple ID, using **SideStore**, **AltStore** or **Sideloadly**. Apps signed with a free Apple ID must be refreshed every 7 days.
3. On the phone, trust your developer profile: Settings → General → VPN & Device Management.
4. Turn on **Developer Mode**: Settings → Privacy & Security → Developer Mode. The phone restarts.

## 2. Set up StikDebug (JIT)
1. Install **StikDebug** (3.1.14 or newer; older versions fail on iOS 27) and import its pairing file, as its own guide explains.
2. In StikDebug's Home tab, long-press **Voxelium** → **Assign Script** → `universal.js`, StikDebug's built-in script. Voxelium also puts `UniversalJIT26.js` (from Amethyst) in its Documents folder, if you prefer that one.
3. From now on, **start Voxelium from StikDebug**. Opened from the Home Screen, it can browse and install, but cannot start Minecraft.

## 3. Sign in and play
1. **Account tab:** Sign in with Microsoft. Copy the code and open the sign-in page. Tokens are kept in the iOS Keychain; passwords never reach Voxelium.
2. **Versions tab:** Install a version (1.13 – 26.1.2). For mods, pick Fabric or Quilt in the install sheet, or tap **Modpacks** to install a whole pack.
3. Under **Installed**, tap **Play → Launch Minecraft**.

## Mods, packs and shaders
- Installed version → **Play → Mods & packs…**. Tap **+** to browse Modrinth or import files. Switch mods on and off, and update them when Voxelium finds newer versions.
- Shader packs need **Iris** (offered when missing). BSL and MakeUp Ultra Fast work. Packs that need compute shaders, such as Photon, cannot run on iOS's OpenGL ES 3.0.
- **Memory:** keep the render distance at **8–10** with shaders. Higher values can use more memory than iOS allows, and the game closes. The gauge under **More** in game turns orange, then red, as memory fills.

## Known limits
- Minecraft 26.2 and newer are not supported yet (26.2 renders black; 26.3+ needs Vulkan). Versions 1.12.2 and older are not supported.
- Forge and NeoForge are not supported yet; they are planned for the first update.
- Very large modpacks (hundreds of mods) do not fit in iPhone memory.
- If StikDebug stops (for example after a long download), close Voxelium and start it from StikDebug again.

## When something goes wrong
- **Logs tab:** the launcher log. `Library/Application Support/Voxelium/logs/jvm.log` holds the game's output.
- Report problems with your device, iOS version, Voxelium version (Diagnostics → About) and both logs.
