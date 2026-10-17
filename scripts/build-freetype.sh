#!/usr/bin/env bash
# Builds FreeType (FTL or GPL-2.0, dual-licensed) for iOS arm64 from source, as
# the libfreetype.dylib that LWJGL's FreeType binding loads. Minecraft 1.20.5 and
# later (lwjgl-freetype) need it for text rendering. No optional dependencies
# (zlib, bzip2, png, harfbuzz, brotli). Needs CMake from scripts/build-mobileglues.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
SRC="$DEPS/freetype"
BUILD="$DEPS/freetype-build"
OUT="$DEPS/freetype-out"
TAG="VER-2-13-3"
IOS_MIN="16.0"
CMAKE="$DEPS/cmake-4.4.4-macos-universal/CMake.app/Contents/bin/cmake"
[ -x "$CMAKE" ] || { echo "CMake missing; run scripts/build-mobileglues.sh first" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://github.com/freetype/freetype.git
fi
git -C "$SRC" fetch -q --depth 1 origin "refs/tags/$TAG"
git -C "$SRC" checkout -q FETCH_HEAD
echo "FreeType $TAG -> $(git -C "$SRC" rev-parse HEAD)"

"$CMAKE" -S "$SRC" -B "$BUILD" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
  -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
  -DCMAKE_INSTALL_NAME_DIR=@rpath
"$CMAKE" --build "$BUILD" -j "$(sysctl -n hw.ncpu)" --target freetype

rm -rf "$OUT"
mkdir -p "$OUT"
LIB=$(find "$BUILD" -maxdepth 2 -name 'libfreetype*.dylib' -type f | head -1)
[ -n "$LIB" ] || { echo "libfreetype not produced" >&2; exit 1; }
cp "$LIB" "$OUT/libfreetype.dylib"
install_name_tool -id @rpath/libfreetype.dylib "$OUT/libfreetype.dylib"
platform=$(otool -l "$OUT/libfreetype.dylib" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
[ "$platform" = "2" ] || { echo "not an iOS binary (platform $platform)" >&2; exit 1; }
nm -gU "$OUT/libfreetype.dylib" | grep -c ' _FT_' | xargs echo "exported FT_ functions:"
ls -la "$OUT"
otool -L "$OUT/libfreetype.dylib"
