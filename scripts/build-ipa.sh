#!/usr/bin/env bash
# Builds an UNSIGNED iOS IPA into build/ipa/. Unsigned IPAs cannot be
# installed as-is; sign them with Xcode (free Apple ID), SideStore or AltStore.
# Requires: Xcode with the license accepted (sudo xcodebuild -license accept).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
CONFIG="${CONFIG:-Release}"
DERIVED="$OUT/DerivedData"
IPA_DIR="$OUT/ipa"

cd "$ROOT"
mkdir -p "$IPA_DIR" "$OUT/logs"
# Unique, increasing build number (CFBundleVersion), visible in
# `xcrun devicectl device info apps`, so the installed build can be identified.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

# The Forge/NeoForge entry point is small and quick to build, so always rebuild it.
echo "==> voxelium-boot.jar"
"$ROOT/scripts/build-boot.sh" > /dev/null
# Voxelium 2.0 ships both renderers: MobileGlues (OpenGL ES on ANGLE) and Vulkan
# (KosmicKrisp; Zink for 1.17 - 26.1.2, SDL3 + native Vulkan for 26.3+). The same
# settings the experimental IPA used, with the normal bundle ID. The Vulkan parts need
# iOS 26 (Metal 4); on older iOS the app offers MobileGlues only.
echo "==> xcodebuild ($CONFIG, generic iOS device, signing disabled, MobileGlues + Vulkan)"
xcodebuild \
  -project App/Voxelium.xcodeproj \
  -scheme Voxelium \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  VOXELIUM_ZINK=YES \
  VOXELIUM_SDL3=YES \
  HEADER_SEARCH_PATHS='$(inherited) $(PROJECT_DIR)/../build/deps/sdl3-out/include' \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) VOXELIUM_ZINK_EXPERIMENT' \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) VOXELIUM_ZINK_EXPERIMENT=1' \
  build > "$OUT/logs/xcodebuild-$CONFIG.log" 2>&1 && XCB=0 || XCB=$?
# (Checking PIPESTATUS after "| grep ... || true" read the status of "true", so a
# failed build used to go on and package the previous .app.)
grep -E "error:|warning: .*Voxelium|BUILD (SUCCEEDED|FAILED)" "$OUT/logs/xcodebuild-$CONFIG.log" || true
[ "$XCB" -eq 0 ] || { echo "xcodebuild failed ($XCB); see $OUT/logs/xcodebuild-$CONFIG.log"; exit 1; }

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/Voxelium.app"
[ -d "$APP" ] || { echo "missing $APP"; exit 1; }
[ -f "$APP/java/voxelium-boot.jar" ] || { echo "missing java/voxelium-boot.jar in the app (Forge/NeoForge)"; exit 1; }
# Vulkan renderer parts (2.0): Zink + KosmicKrisp, SDL3 + the Vulkan shim, LWJGL 3.4.3.
for need in Frameworks/zink Frameworks/sdl3/libSDL3.dylib Frameworks/sdl3/libvulkan.1.dylib java/lwjgl-3.4.3/lwjgl.jar; do
  [ -e "$APP/$need" ] || { echo "missing $need in the app (Vulkan renderer); build its deps first"; exit 1; }
done
[ "$(grep -a -c "VOXELIUM_SDL_VULKAN_OK" "$APP/Voxelium")" -gt 0 ] || { echo "Vulkan code not compiled in (VOXELIUM_ZINK_EXPERIMENT or SDL headers missing)"; exit 1; }

echo "==> packaging"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
IPA="$IPA_DIR/Voxelium-unsigned.ipa"
rm -f "$IPA"
(cd "$STAGE" && /usr/bin/zip -qry "$IPA" Payload)
rm -rf "$STAGE"

echo "==> verification"
PLIST="$APP/Info.plist"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
MINOS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")
ARCHS=$(lipo -archs "$APP/Voxelium")
PLATFORM=$(otool -l "$APP/Voxelium" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
SIZE=$(stat -f%z "$IPA")
SHA=$(shasum -a 256 "$IPA" | awk '{print $1}')
SIGN=$(codesign -dv "$APP" 2>&1 | head -1 || true)

{
  echo "ipa=$IPA"
  echo "size_bytes=$SIZE"
  echo "sha256=$SHA"
  echo "bundle_id=$BUNDLE_ID"
  echo "version=$VERSION ($BUILD)"
  echo "minimum_ios=$MINOS"
  echo "archs=$ARCHS"
  echo "macho_platform=$PLATFORM (2 = iOS)"
  echo "codesign=$SIGN"
  echo "commit=$(git rev-parse --verify -q HEAD || echo none)$(git diff --quiet HEAD 2>/dev/null || echo " (working tree has uncommitted changes)")"
  echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
} | tee "$IPA_DIR/Voxelium-unsigned.ipa.info"
echo "$SHA  Voxelium-unsigned.ipa" > "$IPA_DIR/Voxelium-unsigned.ipa.sha256"
unzip -l "$IPA" | tail -1
