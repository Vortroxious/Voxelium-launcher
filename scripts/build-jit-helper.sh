#!/usr/bin/env bash
# The built-in JIT helper (docs/JIT_INTEGRATION_PLAN.md, Phase 2): builds App/JITHelper
# together with StikJIT's sources into VoxeliumJITHelper.appex and puts it in <app>/PlugIns.
# Run by scripts/build-ipa.sh.
# Unsigned, like the rest of the IPA; the signing tool signs it with the app.
#   scripts/build-jit-helper.sh path/to/Voxelium.app
#
# StikJIT (MPL-2.0) is fetched at a pinned commit into build/deps/stikjit-src. Its
# idevice library (MIT) comes prebuilt in that repository (idevice/libidevice_ffi.a).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: build-jit-helper.sh path/to/Voxelium.app}"
SRC="$ROOT/App/JITHelper"
APPEX="$APP/PlugIns/VoxeliumJITHelper.appex"
PB=/usr/libexec/PlistBuddy
STIKJIT_COMMIT=0129e21955011a9aee47706d7ce178683208e88a   # StikJIT 1.7.x, 2026-09-27
STIK="$ROOT/build/deps/stikjit-src"
MIN_IOS=17.4   # StikJIT's deployment target

if [ "$(cat "$STIK/.voxelium-commit" 2>/dev/null)" != "$STIKJIT_COMMIT" ]; then
  echo "==> fetching StikJIT $STIKJIT_COMMIT"
  rm -rf "$STIK"; mkdir -p "$STIK"
  curl -sfL "https://codeload.github.com/StikDebug/StikJIT/tar.gz/$STIKJIT_COMMIT" | tar -xz -C "$STIK" --strip-components=1
  echo "$STIKJIT_COMMIT" > "$STIK/.voxelium-commit"
fi

rm -rf "$APPEX"
mkdir -p "$APPEX"
# One module: StikJIT's sources plus the helper. Entry point NSExtensionMain (Foundation).
xcrun -sdk iphoneos swiftc -target "arm64-apple-ios$MIN_IOS" -swift-version 5 -O \
  -parse-as-library -application-extension -module-name VoxeliumJITHelper \
  -I "$STIK/idevice" -I "$STIK/iokit" \
  "$STIK"/Sources/*.swift "$SRC/JITHelper.swift" \
  -L "$STIK/idevice" -Xlinker -hidden-lidevice_ffi \
  -framework JavaScriptCore -framework Network -framework Security -framework CFNetwork \
  -framework SystemConfiguration -framework IOKit \
  -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -dead_strip \
  -o "$APPEX/VoxeliumJITHelper"

# Same identity and SDK keys as the app; the extension's ID must start with the app's.
cp "$SRC/Info.plist" "$APPEX/Info.plist"
P="$APPEX/Info.plist"
APP_ID=$($PB -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
$PB -c "Add :CFBundleIdentifier string $APP_ID.JITHelper" "$P"
for key in CFBundleShortVersionString CFBundleVersion DTPlatformName DTPlatformVersion \
           DTPlatformBuild DTSDKName DTSDKBuild DTXcode DTXcodeBuild DTCompiler BuildMachineOSBuild; do
  v=$($PB -c "Print :$key" "$APP/Info.plist" 2>/dev/null) || continue
  $PB -c "Add :$key string $v" "$P"
done
$PB -c "Add :MinimumOSVersion string $MIN_IOS" "$P"
plutil -convert binary1 "$P"
echo "jit_helper=$APPEX ($APP_ID.JITHelper, StikJIT ${STIKJIT_COMMIT:0:7}, $(stat -f%z "$APPEX/VoxeliumJITHelper") bytes)"
