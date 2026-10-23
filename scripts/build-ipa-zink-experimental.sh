#!/usr/bin/env bash
# Builds the UNSIGNED experimental Zink IPA into build/ipa-experimental/: the
# app plus Mesa's Zink (desktop GL on Vulkan, scripts/build-zink.sh) in
# Frameworks/zink and the "Zink test (experimental)" graphics test, and SDL3
# (scripts/build-sdl3.sh) in Frameworks/sdl3 with the "SDL + Vulkan test"
# (Minecraft 26.3 feasibility; compiled in only if SDL3 is built). It has its
# own bundle ID and DerivedData, so it installs beside Voxelium and never
# touches the shipping build or the IPAs in build/ipa/ (checked below).
#   ZINK_VK=kosmickrisp|moltenvk  which build/deps/zink-out/<vk> to bundle
#                                 (default: kosmickrisp if built, else moltenvk)
# Sign it like the normal IPA (Xcode with a free Apple ID, SideStore, AltStore).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
CONFIG="${CONFIG:-Release}"
# DERIVED and IPA_NAME can be overridden, so parallel experiments keep their own IPA.
DERIVED="${DERIVED:-$OUT/DerivedData-zink-exp}"
IPA_DIR="$OUT/ipa-experimental"
IPA_NAME="${IPA_NAME:-Voxelium-zink-experimental-unsigned.ipa}"
LOG="$OUT/logs/xcodebuild-$(basename "$DERIVED")-$CONFIG.log"

cd "$ROOT"
mkdir -p "$IPA_DIR" "$OUT/logs"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

# The shipping IPAs must come out of this byte-for-byte unchanged.
GUARDED=("$OUT/ipa/Voxelium-1.0-unsigned.ipa" "$OUT/ipa/Voxelium-unsigned.ipa")
guard_hashes() {
  for f in "${GUARDED[@]}"; do
    if [ -f "$f" ]; then echo "$(shasum -a 256 "$f" | awk '{print $1}')  $f"; else echo "absent  $f"; fi
  done
}
BEFORE="$(guard_hashes)"
echo "==> shipping IPAs before"
echo "$BEFORE"

echo "==> voxelium-boot.jar"
"$ROOT/scripts/build-boot.sh" > /dev/null
echo "==> xcodebuild ($CONFIG, generic iOS device, signing disabled, Zink experiment)"
xcodebuild \
  -project App/Voxelium.xcodeproj \
  -scheme Voxelium \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  VOXELIUM_ZINK=YES \
  VOXELIUM_ZINK_VK="${ZINK_VK:-}" \
  VOXELIUM_SDL3=YES \
  HEADER_SEARCH_PATHS='$(inherited) $(PROJECT_DIR)/../build/deps/sdl3-out/include' \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) VOXELIUM_ZINK_EXPERIMENT' \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) VOXELIUM_ZINK_EXPERIMENT=1' \
  PRODUCT_BUNDLE_IDENTIFIER=io.github.voxelium.launcher.zinkexp \
  INFOPLIST_KEY_CFBundleDisplayName="Voxelium Zink Exp" \
  build > "$LOG" 2>&1 && XCB=0 || XCB=$?
grep -E "error:|warning: .*(Voxelium|Zink|SDL)|note: bundled (Zink|SDL3)|BUILD (SUCCEEDED|FAILED)" "$LOG" || true
[ "$XCB" -eq 0 ] || { echo "xcodebuild failed ($XCB); see $LOG"; exit 1; }

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/Voxelium.app"
[ -d "$APP" ] || { echo "missing $APP"; exit 1; }
[ -f "$APP/java/voxelium-boot.jar" ] || { echo "missing java/voxelium-boot.jar in the app (Forge/NeoForge)"; exit 1; }
[ -d "$APP/Frameworks/zink" ] || { echo "missing Frameworks/zink in the app (Bundle Zink phase did not run with VOXELIUM_ZINK=YES)"; exit 1; }
# (grep -c, not -q: with pipefail an early grep exit fails nm with SIGPIPE.)
[ "$(nm -U "$APP/Voxelium" | grep -c "VXZinkTest\|ZinkTestRows")" -gt 0 ] || { echo "Zink test is not compiled in (VOXELIUM_ZINK_EXPERIMENT not applied)"; exit 1; }
[ -d "$APP/Frameworks/sdl3" ] || { echo "missing Frameworks/sdl3 in the app (Bundle SDL3 phase did not run with VOXELIUM_SDL3=YES)"; exit 1; }
if [ -f "$APP/Frameworks/sdl3/libSDL3.dylib" ]; then
  # The test's body needs SDL's headers; without them it only reports that.
  [ "$(grep -a -c "VOXELIUM_SDL_VULKAN_OK" "$APP/Voxelium")" -gt 0 ] || { echo "SDL + Vulkan test is not compiled in (SDL headers not found)"; exit 1; }
else
  echo "warning: Frameworks/sdl3 is empty; build SDL3 first (scripts/build-sdl3.sh). The SDL test will report it missing."
fi

echo "==> packaging"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
IPA="$IPA_DIR/$IPA_NAME"
rm -f "$IPA"
(cd "$STAGE" && /usr/bin/zip -qry "$IPA" Payload)
rm -rf "$STAGE"

echo "==> verification"
PLIST="$APP/Info.plist"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
MINOS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")
ARCHS=$(lipo -archs "$APP/Voxelium")
PLATFORM=$(otool -l "$APP/Voxelium" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
SIZE=$(stat -f%z "$IPA")
SHA=$(shasum -a 256 "$IPA" | awk '{print $1}')
SIGN=$(codesign -dv "$APP" 2>&1 | head -1 || true)
ZINK_FILES=$(cd "$APP/Frameworks/zink" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')
SDL_FILES=$(cd "$APP/Frameworks/sdl3" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')
SDL_SHA=$([ -f "$APP/Frameworks/sdl3/libSDL3.dylib" ] && shasum -a 256 "$APP/Frameworks/sdl3/libSDL3.dylib" | awk '{print $1}' || echo none)
[ "$BUNDLE_ID" = "io.github.voxelium.launcher.zinkexp" ] || { echo "unexpected bundle ID $BUNDLE_ID"; exit 1; }
[ -f "$APP/Frameworks/zink/libEGL_mesa.dylib" ] || echo "warning: Frameworks/zink is empty; build Mesa first (scripts/build-zink.sh). The Zink test will report it missing."

{
  echo "ipa=$IPA"
  echo "size_bytes=$SIZE"
  echo "sha256=$SHA"
  echo "bundle_id=$BUNDLE_ID"
  echo "display_name=$DISPLAY_NAME"
  echo "version=$VERSION ($BUILD)"
  echo "minimum_ios=$MINOS"
  echo "archs=$ARCHS"
  echo "macho_platform=$PLATFORM (2 = iOS)"
  echo "codesign=$SIGN"
  echo "zink_vk=${ZINK_VK:-auto}"
  echo "frameworks_zink=${ZINK_FILES:-(empty)}"
  echo "frameworks_sdl3=${SDL_FILES:-(empty)}"
  echo "libSDL3_sha256=$SDL_SHA"
  echo "commit=$(git rev-parse --verify -q HEAD || echo none)$(git diff --quiet HEAD 2>/dev/null || echo " (working tree has uncommitted changes)")"
  echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
} | tee "$IPA_DIR/$IPA_NAME.info"
echo "$SHA  $IPA_NAME" > "$IPA_DIR/$IPA_NAME.sha256"
unzip -l "$IPA" | tail -1

AFTER="$(guard_hashes)"
if [ "$BEFORE" != "$AFTER" ]; then
  echo "error: a shipping IPA in build/ipa/ changed during this build:"
  diff <(echo "$BEFORE") <(echo "$AFTER") || true
  exit 1
fi
echo "==> shipping IPAs unchanged"
