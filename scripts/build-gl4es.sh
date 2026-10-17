#!/usr/bin/env bash
# Builds gl4es (MIT) for iOS arm64 from source as libgl4es.dylib: OpenGL 2.1 with
# the fixed-function pipeline, translated to OpenGL ES 2 on the app's ANGLE
# context. Minecraft 1.13 - 1.16.5 render with fixed-function GL (glFog, matrix
# stacks...), which MobileGlues does not provide; Amethyst-iOS and ZalithLauncher
# use gl4es for those versions too. Uses PojavLauncherTeam's iOS branch.
#
# NOX11 + NOEGL: the context is created outside gl4es (by the app's GLFW, on
# ANGLE). gl4es dlopens the GLES library named by LIBGL_GLES (set by the app to
# ANGLE's libGLESv2) and resolves the real GLES functions from it (our patch;
# upstream's Apple path only tries dlsym(RTLD_NEXT, ...)).
# Needs CMake from scripts/build-mobileglues.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
SRC="$DEPS/gl4es"
BUILD="$DEPS/gl4es-build"
OUT="$DEPS/gl4es-out"
REPO="https://github.com/PojavLauncherTeam/gl4es.git"
BRANCH="mergewithios"
REV="${GL4ES_REV:-c3d6a54f8a2cd7672f345f6421578f6e0d619292}"
IOS_MIN="16.0"
CMAKE="$DEPS/cmake-4.4.4-macos-universal/CMake.app/Contents/bin/cmake"
[ -x "$CMAKE" ] || { echo "CMake missing; run scripts/build-mobileglues.sh first" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  git clone -q --depth 1 --branch "$BRANCH" "$REPO" "$SRC"
fi
if [ "$(git -C "$SRC" rev-parse HEAD)" != "$REV" ]; then
  git -C "$SRC" fetch -q --depth 1 origin "$REV"
  git -C "$SRC" checkout -q "$REV"
fi
echo "gl4es $BRANCH -> $(git -C "$SRC" rev-parse HEAD)"
# Our patch (patches/gl4es/): look GLES up in the LIBGL_GLES library on Apple, and
# do not link the branch's prebuilt MetalANGLE.framework.
git -C "$SRC" checkout -q -- . && git -C "$SRC" clean -fdq
git -C "$SRC" apply "$ROOT/patches/gl4es/0001-ios-use-app-angle.patch"

"$CMAKE" -S "$SRC" -B "$BUILD" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DNOX11=ON -DNOEGL=ON -DDEFAULT_ES=2 \
  -DCMAKE_INSTALL_NAME_DIR=@rpath \
  -DCMAKE_C_FLAGS="-Wno-error -Wno-int-conversion -Wno-incompatible-function-pointer-types -Wno-implicit-function-declaration"
"$CMAKE" --build "$BUILD" -j "$(sysctl -n hw.ncpu)" --target GL

rm -rf "$OUT"
mkdir -p "$OUT"
LIB=$(find "$SRC/lib" "$BUILD" -name 'libGL*.dylib' -type f 2>/dev/null | head -1)  # gl4es writes to its own lib/
[ -n "$LIB" ] || { echo "libGL not produced" >&2; find "$BUILD" -name 'libGL*' >&2; exit 1; }
cp "$LIB" "$OUT/libgl4es.dylib"
install_name_tool -id @rpath/libgl4es.dylib "$OUT/libgl4es.dylib"
platform=$(otool -l "$OUT/libgl4es.dylib" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
[ "$platform" = "2" ] || { echo "not an iOS binary (platform $platform)" >&2; exit 1; }
for f in OSMesaGetProcAddress gl4es_GetProcAddress gl4es_glFogfv gl4es_glBegin initialize_gl4es; do
  printf "%-20s %s\n" "$f" "$(nm -gU "$OUT/libgl4es.dylib" | grep -c " _$f$")"
done
ls -la "$OUT"
otool -L "$OUT/libgl4es.dylib"
