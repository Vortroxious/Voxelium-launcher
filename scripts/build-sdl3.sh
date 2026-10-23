#!/usr/bin/env bash
# Builds SDL 3.4.14 (zlib) for iOS arm64 as the libSDL3.dylib LWJGL 3.4.3's
# lwjgl-sdl binding loads. Minecraft 26.3 replaced GLFW with SDL3 and asks it
# for its window and Vulkan surface. 3.4.14 is the version Mojang bundles in
# lwjgl-sdl-3.4.3-natives-*. Patched by patches/sdl3/ so that SDL can be driven
# from Minecraft's thread inside our app (UIKit work on the main thread, no
# run-loop pumping off it, window above the launcher in landscape, no SDL_main).
# Uses UIKit video with Vulkan (VK_EXT_metal_surface) and Metal; Vulkan comes
# from the app at run time (SDL_Vulkan_LoadLibrary). Needs CMake from
# scripts/build-mobileglues.sh. Output: build/deps/sdl3-out/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
SRC="$DEPS/sdl3"
BUILD="$DEPS/sdl3-build"
OUT="$DEPS/sdl3-out"
TAG="release-3.4.14"
REV="147a8ee32dbf9ac02f3794964490687b6bbda1bc"   # the commit $TAG points to
IOS_MIN="26.0"   # the Vulkan driver (KosmicKrisp) needs Metal 4
CMAKE="$DEPS/cmake-4.4.4-macos-universal/CMake.app/Contents/bin/cmake"
[ -x "$CMAKE" ] || { echo "CMake missing; run scripts/build-mobileglues.sh first" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://github.com/libsdl-org/SDL.git
fi
git -C "$SRC" fetch -q --depth 1 origin "refs/tags/$TAG"
got="$(git -C "$SRC" rev-parse FETCH_HEAD^{commit})"
[ "$got" = "$REV" ] || { echo "$TAG is $got, expected $REV" >&2; exit 1; }
git -C "$SRC" checkout -q -f "$REV"
git -C "$SRC" clean -qfd
for p in "$ROOT"/patches/sdl3/*.patch; do
  echo "applying $(basename "$p")"
  git -C "$SRC" apply "$p"
done
echo "SDL $TAG -> $REV"

rm -rf "$BUILD"
"$CMAKE" -S "$SRC" -B "$BUILD" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF \
  -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL=OFF \
  -DSDL_FRAMEWORK=OFF \
  -DSDL_VULKAN=ON -DSDL_METAL=ON \
  -DSDL_AUDIO=OFF \
  -DCMAKE_INSTALL_NAME_DIR=@rpath
# Audio is off: Minecraft plays sound through OpenAL (libopenal.dylib), and
# SDL's CoreAudio backend would only add an AVAudioSession user.
"$CMAKE" --build "$BUILD" -j "$(sysctl -n hw.ncpu)" --target SDL3-shared

rm -rf "$OUT"
mkdir -p "$OUT/include" "$OUT/LICENSES"
LIB=$(find "$BUILD" -maxdepth 1 -name 'libSDL3*.dylib' -type f | head -1)
[ -n "$LIB" ] || { echo "libSDL3 not produced" >&2; find "$BUILD" -maxdepth 1 -name '*SDL3*' >&2; exit 1; }
cp "$LIB" "$OUT/libSDL3.dylib"
install_name_tool -id @rpath/libSDL3.dylib "$OUT/libSDL3.dylib"
codesign --force --sign - --timestamp=none "$OUT/libSDL3.dylib"
# Headers for the app's SDL + Vulkan test: SDL's own, plus the Vulkan headers
# SDL carries (src/video/khronos), so the test needs no Vulkan SDK.
cp -R "$SRC/include/SDL3" "$OUT/include/"
cp -R "$SRC/src/video/khronos/vulkan" "$SRC/src/video/khronos/vk_video" "$OUT/include/"
cp "$SRC/LICENSE.txt" "$OUT/LICENSES/SDL3-LICENSE.txt"
{
  echo "SDL $TAG ($REV), zlib licence, https://github.com/libsdl-org/SDL"
  echo "iOS arm64, minimum iOS $IOS_MIN, built by scripts/build-sdl3.sh with patches/sdl3/:"
  (cd "$ROOT/patches/sdl3" && ls *.patch | sed 's/^/  /')
} > "$OUT/LICENSES/SDL3-BUILD-INFO.txt"

platform=$(otool -l "$OUT/libSDL3.dylib" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
[ "$platform" = "2" ] || { echo "not an iOS binary (platform $platform)" >&2; exit 1; }
minos=$(otool -l "$OUT/libSDL3.dylib" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
[ "$minos" = "$IOS_MIN" ] || { echo "minos $minos, expected $IOS_MIN" >&2; exit 1; }
for s in SDL_Init SDL_CreateWindow SDL_Vulkan_LoadLibrary SDL_Vulkan_CreateSurface SDL_PollEvent; do
  # (grep -c, not -q: with pipefail an early grep exit fails nm with SIGPIPE.)
  [ "$(nm -gU "$OUT/libSDL3.dylib" | grep -c " _$s$")" -gt 0 ] || { echo "libSDL3.dylib does not export $s" >&2; exit 1; }
done
ls -la "$OUT"
otool -L "$OUT/libSDL3.dylib"
shasum -a 256 "$OUT/libSDL3.dylib"
