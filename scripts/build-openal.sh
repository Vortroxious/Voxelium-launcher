#!/usr/bin/env bash
# Builds openal-soft (LGPL-2.0-or-later) for iOS arm64 from source, as the
# libopenal.dylib LWJGL's OpenAL binding loads (Minecraft's sound engine
# initialises it at start-up and does not survive it being missing).
# Uses the CoreAudio backend. Needs CMake from scripts/build-mobileglues.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
SRC="$DEPS/openal-soft"
BUILD="$DEPS/openal-build"
OUT="$DEPS/openal-out"
TAG="1.25.2"
IOS_MIN="16.0"
CMAKE="$DEPS/cmake-4.4.4-macos-universal/CMake.app/Contents/bin/cmake"
[ -x "$CMAKE" ] || { echo "CMake missing; run scripts/build-mobileglues.sh first" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://github.com/kcat/openal-soft.git
fi
git -C "$SRC" fetch -q --depth 1 origin "refs/tags/$TAG"
git -C "$SRC" checkout -q FETCH_HEAD
echo "openal-soft $TAG -> $(git -C "$SRC" rev-parse HEAD)"

"$CMAKE" -S "$SRC" -B "$BUILD" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_BUILD_TYPE=Release \
  -DLIBTYPE=SHARED \
  -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DALSOFT_INSTALL=OFF \
  -DALSOFT_REQUIRE_COREAUDIO=ON \
  -DALSOFT_OSX_FRAMEWORK=OFF \
  -DCMAKE_INSTALL_NAME_DIR=@rpath \
  -DHAVE_WFUNCTION_EFFECTS=OFF \
  -DHAVE_LIBATOMIC=OFF \
  -DCMAKE_CXX_FLAGS="-Wno-error=function-effects"
# Xcode 27 clang errors on coreaudio.cpp's `nonblocking` function-effect casts
# (-Wfunction-effects). openal-soft re-enables that diagnostic after our flags
# when its compiler probe succeeds, so pre-answer the probe and keep it a
# warning rather than patching the source.
# HAVE_LIBATOMIC: with STATIC_LIBRARY try-compiles the "needs -latomic" probe
# cannot see link failures and wrongly adds -latomic, which Apple lacks.
"$CMAKE" --build "$BUILD" -j "$(sysctl -n hw.ncpu)" --target OpenAL

rm -rf "$OUT"
mkdir -p "$OUT"
LIB=$(find "$BUILD" -maxdepth 2 -name 'libopenal*.dylib' -type f | head -1)
[ -n "$LIB" ] || { echo "libopenal not produced" >&2; find "$BUILD" -maxdepth 2 -name '*openal*' >&2; exit 1; }
cp "$LIB" "$OUT/libopenal.dylib"
install_name_tool -id @rpath/libopenal.dylib "$OUT/libopenal.dylib"
platform=$(otool -l "$OUT/libopenal.dylib" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
[ "$platform" = "2" ] || { echo "not an iOS binary (platform $platform)" >&2; exit 1; }
ls -la "$OUT"
otool -L "$OUT/libopenal.dylib"
