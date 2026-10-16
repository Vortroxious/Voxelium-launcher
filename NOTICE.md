# Notices

This project is licensed under GPL-3.0 (see `LICENSE`).

It is an independent iOS project **inspired by** [ZalithLauncher2](https://github.com/ZalithLauncher/ZalithLauncher2) (GPL-3.0, © ZalithLauncher contributors). That project builds on [PojavLauncher](https://github.com/PojavLauncherTeam/PojavLauncher) (LGPL-3.0/GPL-3.0). It is not affiliated with, or endorsed by, the ZalithLauncher team, Mojang Studios or Microsoft.

- No ZalithLauncher2 source files are included. Behaviour that mirrors upstream is cited in code comments.
- ZalithLauncher2's README adds GPLv3 §7 terms: keep copyright notices, and distinguish modified versions by name or version. This project uses its own name and version (0.x). The name still contains "Zalith". Before any public release, confirm with the maintainers or rename (open item).
- "Minecraft" is a trademark of Mojang Synergies AB. This launcher does not include or redistribute any Minecraft game files. They are downloaded from Mojang's servers to the user's device.

## Bundled third-party components (in the IPA)
- **OpenJDK 17.0.20 runtime for iOS arm64**, built by AngelAuraMC (https://assets.angelauramc.dev/openjdk/ios-arm64/jre17-ios-aarch64.zip). License: GPL-2.0 with the Classpath Exception. Per-module notices ship in `java/jre17/legal/` inside the app.
- **UniversalJIT26.js, UniversalJIT26Extension.js** from Amethyst-iOS (GPL-3.0), unmodified apart from a header comment.
- **jni.h, jni_md.h** from OpenJDK 17u (GPL-2.0 with the Classpath Exception).
- `App/ZalithIOS/Native/JITSupport.m` adapts JIT detection and breakpoint helpers from Amethyst-iOS `Natives/utils.m` (GPL-3.0).
