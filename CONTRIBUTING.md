# Contributing

1. Run the core tests before sending changes:
   ```bash
   swift test
   ```
2. Build the app for the simulator (needs Xcode with the license accepted):
   ```bash
   xcodebuild -project App/Voxelium.xcodeproj -scheme Voxelium -destination 'generic/platform=iOS Simulator' build
   ```
3. **Claims need evidence.** Do not mark a feature as working in `README.md` or `docs/` unless you have a reproducible test or a device log. Record results in `docs/ENGINEERING_LOG.md` with date, device and iOS version.
4. Do not copy code from other launchers without recording its source, commit and license in the file header and in `docs/DEPENDENCY_INVENTORY.md`.
5. Never commit signing certificates, provisioning profiles, pairing files, Apple IDs or account tokens.
