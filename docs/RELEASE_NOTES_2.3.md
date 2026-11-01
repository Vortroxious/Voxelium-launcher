# Voxelium 2.3

**JIT without StikDebug.** Voxelium now turns on JIT itself. It has a built-in helper (StikJIT, the engine inside StikDebug), so you only need LocalDevVPN and your iPhone's pairing file. Tap Play and the game starts, without switching apps.

> Not affiliated with Mojang, Microsoft, Modrinth, the Forge or NeoForge projects, or StikDebug. You need a Minecraft: Java Edition account, iOS 17.4 or later, LocalDevVPN and a pairing file. See the [install guide](../README.md#installing-on-your-iphone).

## New
- **Built-in JIT.**
  - A new **JIT** tab: import your iPhone's pairing file once (made with idevice_pair on a computer). Voxelium keeps it in the iOS Keychain.
  - Play turns on JIT in about 2 seconds.
  - The first time, Voxelium downloads and mounts the iPhone's developer disk image. It needs internet and took about 40 seconds in testing.
  - **StikDebug is optional.** Without a pairing file, or with the built-in helper turned off in the JIT tab, Play asks StikDebug as in 2.2.
- **Clear messages** when JIT can't start: "LocalDevVPN isn't connected", "This pairing file doesn't work", "Import a pairing file", with a button to import one.
- **Playing on mobile data.**
  - LocalDevVPN only works on Wi-Fi or in Airplane Mode. On mobile data, Play now asks you to turn on Airplane Mode, goes on by itself, and tells you when you can turn it off again.
  - **Offline play:** if Voxelium can't reach Microsoft (in Airplane Mode, for example), it uses your saved sign-in. Single-player works; servers and Realms need internet. Voxelium refreshes the sign-in early while you're online, so it stays valid longer.
- **Logs** moved to **Diagnostics → Logs**; the JIT tab took their place.

## Tested
With the built-in helper (test builds of this release):
- **iPhone 15 Pro Max, iOS 27.0:** JIT on in 1.5–1.8 s; Fabric 1.21.11 joined a world. Also tested: after a restart, without LocalDevVPN, without a pairing file (StikDebug, then the "Import a pairing file" message), with a broken pairing file, in Airplane Mode with the saved sign-in, and with Airplane Mode turned off right after JIT.
- **iPhone 14 Pro Max, iOS 26.1**, which had never had a developer disk image: the helper downloaded and mounted it, JIT was on after 40 s, and Fabric 1.21.11 joined a world.

Everything else is unchanged from [2.2](RELEASE_NOTES_2.2.md).

## Updating
Install over 2.2 with Sideloadly using the **same Apple ID**. Your versions, mods and worlds stay. Then import your pairing file in the JIT tab: the same file you gave StikDebug works.

## Known limits
- LocalDevVPN must be connected, and on mobile data, Airplane Mode is needed for the 2 seconds it takes to turn on JIT.
- The helper is an app extension, so Voxelium uses two App IDs on your Apple ID (a free Apple ID can register 10 a week).
- The built-in helper needs iOS 17.4 or later. It was tested on iOS 26.1 and 27.0 only.
- 26.3 runs on Vulkan only (iOS 26+). Not supported: 1.12.2 and older, and Forge before 1.17.
- iOS limits the app's memory (about 3.4 GB on the test phone). Apps signed with a free Apple ID must be refreshed every 7 days.

## Licences
The helper adds StikJIT (MPL-2.0, unmodified), idevice (MIT) and the Rust crates it's built from. Their licences are in Diagnostics → About Voxelium & licences and in [THIRD_PARTY_NOTICES.txt](../THIRD_PARTY_NOTICES.txt).
