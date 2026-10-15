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

echo "==> xcodebuild ($CONFIG, generic iOS device, signing disabled)"
xcodebuild \
  -project App/ZalithIOS.xcodeproj \
  -scheme ZalithIOS \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build 2>&1 | tee "$OUT/logs/xcodebuild-$CONFIG.log" | grep -E "error:|warning: .*ZalithIOS|BUILD (SUCCEEDED|FAILED)" || true
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "xcodebuild failed; see $OUT/logs/xcodebuild-$CONFIG.log"; exit 1; }

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/ZalithIOS.app"
[ -d "$APP" ] || { echo "missing $APP"; exit 1; }

echo "==> packaging"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
IPA="$IPA_DIR/ZalithIOS-unsigned.ipa"
rm -f "$IPA"
(cd "$STAGE" && /usr/bin/zip -qry "$IPA" Payload)
rm -rf "$STAGE"

echo "==> verification"
PLIST="$APP/Info.plist"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
MINOS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")
ARCHS=$(lipo -archs "$APP/ZalithIOS")
PLATFORM=$(otool -l "$APP/ZalithIOS" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
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
} | tee "$IPA_DIR/ZalithIOS-unsigned.ipa.info"
echo "$SHA  ZalithIOS-unsigned.ipa" > "$IPA_DIR/ZalithIOS-unsigned.ipa.sha256"
unzip -l "$IPA" | tail -1
