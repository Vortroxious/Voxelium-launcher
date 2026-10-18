#!/usr/bin/env bash
# Builds MobileGlues (desktop OpenGL -> OpenGL ES translation, LGPL-2.1) for
# iOS arm64 from source, together with its shader toolchain, also from
# source: glslang 15.0.0, the SPIRV-Tools/SPIRV-Headers commits glslang pins in
# known_good.json, and SPIRV-Cross vulkan-sdk-1.4.304.0 (C API 0.64, matching
# the headers MobileGlues compiles against). MobileGlues' own prebuilt
# libraries/ios binaries are deleted and replaced with these builds.
#
# MobileGlues commit: the one Amethyst-iOS pins as a submodule (f0fb4d3), which
# has the iOS ("MACOS") build path. It links ANGLE's libEGL/libGLESv2, so run
# scripts/build-angle.sh first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
SRC="$DEPS/mg-src"
PREFIX="$DEPS/mg-prefix"
OUT="$DEPS/mobileglues-out"
ANGLE_OUT="$DEPS/angle/out/ios-arm64"
IOS_MIN="16.0"

CMAKE_V="4.4.4"
CMAKE="$DEPS/cmake-$CMAKE_V-macos-universal/CMake.app/Contents/bin/cmake"
GLSLANG_TAG="15.0.0"                                          # -> 46ef757e048e
SPIRV_TOOLS_REV="6dcc7e350a0b9871a825414d42329e44b0eb8109"    # glslang 15.0.0 known_good.json
SPIRV_HEADERS_REV="2a9b6f951c7d6b04b6c21fe1bf3f475b68b84801"  # glslang 15.0.0 known_good.json
SPIRV_CROSS_TAG="vulkan-sdk-1.4.304.0"
MG_REV="f0fb4d32794a130f4021342605a751ef2d0f84d8"

JOBS="$(sysctl -n hw.ncpu)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

[ -d "$ANGLE_OUT/libEGL.framework" ] && [ -d "$ANGLE_OUT/libGLESv2.framework" ] \
  || { echo "ANGLE not built; run scripts/build-angle.sh" >&2; exit 1; }

# --- CMake (official Kitware release, SHA-256 from Kitware's checksum file)
if [ ! -x "$CMAKE" ]; then
  mkdir -p "$DEPS/cmake-dl"
  (
    cd "$DEPS/cmake-dl"
    curl -fLO "https://github.com/Kitware/CMake/releases/download/v$CMAKE_V/cmake-$CMAKE_V-macos-universal.tar.gz"
    curl -fLO "https://github.com/Kitware/CMake/releases/download/v$CMAKE_V/cmake-$CMAKE_V-SHA-256.txt"
    grep "macos-universal.tar.gz" "cmake-$CMAKE_V-SHA-256.txt" | shasum -a 256 -c -
  )
  tar -xzf "$DEPS/cmake-dl/cmake-$CMAKE_V-macos-universal.tar.gz" -C "$DEPS"
fi

# Clone `url` at `rev` (tag or commit) into `dir`, shallowly.
fetch() {
  local url="$1" rev="$2" dir="$3"
  if [ ! -d "$dir/.git" ]; then
    git init -q "$dir"
    git -C "$dir" remote add origin "$url"
  fi
  git -C "$dir" fetch -q --depth 1 origin "$rev"
  git -C "$dir" checkout -q FETCH_HEAD
}

mkdir -p "$SRC"
fetch https://github.com/KhronosGroup/glslang.git "refs/tags/$GLSLANG_TAG" "$SRC/glslang"
fetch https://github.com/KhronosGroup/SPIRV-Tools.git "$SPIRV_TOOLS_REV" "$SRC/glslang/External/spirv-tools"
fetch https://github.com/KhronosGroup/SPIRV-Headers.git "$SPIRV_HEADERS_REV" "$SRC/glslang/External/spirv-tools/external/spirv-headers"
fetch https://github.com/KhronosGroup/SPIRV-Cross.git "refs/tags/$SPIRV_CROSS_TAG" "$SRC/SPIRV-Cross"
PATCHED="src/main/cpp/egl/loader.cpp src/main/cpp/egl/loader.h src/main/cpp/main.cpp src/main/cpp/includes.h src/main/cpp/init.cpp src/main/cpp/gl/getter.cpp src/main/cpp/gl/gl_stub.cpp src/main/cpp/gl/multidraw.cpp src/main/cpp/gl/gl_native.cpp src/main/cpp/gl/gl.cpp src/main/cpp/gles/loader.h src/main/cpp/gl/program.cpp src/main/cpp/gl/shader.cpp src/main/cpp/gles/loader.cpp src/main/cpp/gl/framebuffer.cpp src/main/cpp/gl/texture.cpp src/main/cpp/gl/drawing.cpp src/main/cpp/gl/buffer.cpp"
[ -d "$SRC/MobileGlues/.git" ] && git -C "$SRC/MobileGlues" checkout -q -- $PATCHED 2>/dev/null || true
fetch https://github.com/MobileGL-Dev/MobileGlues.git "$MG_REV" "$SRC/MobileGlues"
# Our patch (patches/mobileglues/): restore the host's EGL context after init on Apple.
git -C "$SRC/MobileGlues" apply "$ROOT/patches/mobileglues/0001-apple-restore-caller-egl-context.patch"
# And: use std::unordered_map instead of FastSTL, which declares no licence and so
# cannot be redistributed (it is not fetched at all, see below).
git -C "$SRC/MobileGlues" apply "$ROOT/patches/mobileglues/0002-use-std-unordered-map-instead-of-faststl.patch"
# And: on Apple, initialise on the first GL call instead of at load time, so init
# always sees the game's ANGLE context (Minecraft 26.2 loads the library early).
git -C "$SRC/MobileGlues" apply "$ROOT/patches/mobileglues/0003-apple-lazy-init-on-first-gl-call.patch"
# And: implement glMultiDrawArrays, which upstream only stubs (Minecraft 26.2 drew nothing).
git -C "$SRC/MobileGlues" apply "$ROOT/patches/mobileglues/0004-implement-glmultidrawarrays.patch"
# And: glColorMaski falls back to glColorMask below ES 3.2 (Minecraft 26.2 went black).
git -C "$SRC/MobileGlues" apply "$ROOT/patches/mobileglues/0005-colormaski-es30-fallback.patch"
# And: optional GL error reporting, compiled in only with VOXELIUM_MG_CHECK_ERRORS=1.
git -C "$SRC/MobileGlues" apply "$ROOT/patches/mobileglues/0006-optional-gl-error-reporting.patch"
git -C "$SRC/MobileGlues" apply "$ROOT/patches/mobileglues/0007-diagnostic-shader-link-reports.patch"
# And (diagnostic builds only): incomplete framebuffers, texture format errors, GLES caps.
git -C "$SRC/MobileGlues" apply "$ROOT/patches/mobileglues/0008-diagnostic-framebuffer-texture-reports.patch"
# And: copy textures without glGetTexLevelParameteriv, which ES 3.0 lacks (Iris's depth
# copy before translucent terrain failed, so shader-pack water rendered black).
git -C "$SRC/MobileGlues" apply "$ROOT/patches/mobileglues/0009-es30-copy-texture-format-from-tracking.patch"
# And (diagnostic builds only): explain failed draws, ANGLE's debug messages on the game's
# context, and the formats glTexBuffer is asked for.
git -C "$SRC/MobileGlues" apply "$ROOT/patches/mobileglues/0010-diagnostic-draw-error-explanations.patch"
# And: match integer vertex attributes to the shader's signedness (Metal rejects
# unsigned data into ivec inputs: Iris's hand, held and dropped items were not drawn),
# and keep the texture-buffer emulation's last row inside the buffer.
git -C "$SRC/MobileGlues" apply "$ROOT/patches/mobileglues/0011-es30-integer-attribute-signedness-and-tbo-rows.patch"
# Submodules at the commits MobileGlues pins (perfetto is only for PROFILING builds).
MGC="$SRC/MobileGlues/src/main/cpp"
fetch https://github.com/g-truc/glm.git 2d4c4b4dd31fde06cfffad7915c2b3006402322f "$MGC/3rdparty/glm"
fetch https://github.com/stbrumme/xxhash.git c2866db364b6ea3a11933e62235ddc166ba18565 "$MGC/3rdparty/xxhash"
# FastSTL (MobileGL-Dev/FastSTL) is deliberately not fetched: no licence (see patch 0002).
rm -rf "$MGC/include/FastSTL"

IOS_ARGS=(
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_SYSROOT="$SDK"
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
)

# --- glslang + SPIRV-Tools (static)
"$CMAKE" -S "$SRC/glslang" -B "$SRC/build-glslang" "${IOS_ARGS[@]}" \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_OPT=ON -DGLSLANG_TESTS=OFF -DGLSLANG_ENABLE_INSTALL=ON \
  -DENABLE_GLSLANG_BINARIES=OFF -DENABLE_SPVREMAPPER=ON -DENABLE_HLSL=OFF \
  -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON -DSPIRV_TOOLS_BUILD_STATIC=ON
"$CMAKE" --build "$SRC/build-glslang" -j "$JOBS"
"$CMAKE" --install "$SRC/build-glslang"

# --- SPIRV-Cross C API (shared, as MobileGlues expects)
"$CMAKE" -S "$SRC/SPIRV-Cross" -B "$SRC/build-spirv-cross" "${IOS_ARGS[@]}" \
  -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_STATIC=OFF -DSPIRV_CROSS_CLI=OFF \
  -DSPIRV_CROSS_ENABLE_TESTS=OFF -DCMAKE_INSTALL_NAME_DIR=@rpath
"$CMAKE" --build "$SRC/build-spirv-cross" -j "$JOBS"
"$CMAKE" --install "$SRC/build-spirv-cross"

# --- MobileGlues: replace its prebuilt iOS libraries and ANGLE stubs with ours
MG="$SRC/MobileGlues/src/main/cpp"
LIBDIR="$MG/libraries/ios"
rm -rf "$LIBDIR"
mkdir -p "$LIBDIR"
for lib in glslang GenericCodeGen glslang-default-resource-limits MachineIndependent OSDependent \
           SPIRV SPVRemapper SPIRV-Tools SPIRV-Tools-opt SPIRV-Tools-link SPIRV-Tools-lint \
           SPIRV-Tools-reduce SPIRV-Tools-diff; do
  f="$PREFIX/lib/lib$lib.a"
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
  cp "$f" "$LIBDIR/"
done
CROSS=$(find "$PREFIX/lib" -name 'libspirv-cross-c-shared.*.*.*.dylib' | head -1)
[ -n "$CROSS" ] || { echo "SPIRV-Cross shared library missing" >&2; exit 1; }
cp "$CROSS" "$LIBDIR/libspirv-cross-c-shared.dylib"
rm -rf "$MG/external"
mkdir -p "$MG/external"
cp -R "$ANGLE_OUT/libEGL.framework" "$ANGLE_OUT/libGLESv2.framework" "$MG/external/"

# VOXELIUM_MG_CHECK_ERRORS=1: diagnostic build that prints every GLES error (patch 0006).
MG_DIAG_FLAGS=""
[ "${VOXELIUM_MG_CHECK_ERRORS:-0}" = "1" ] && MG_DIAG_FLAGS="-DVOXELIUM_CHECK_GL_ERRORS=1" && echo "==> diagnostic build: GL error reporting on"
"$CMAKE" -S "$MG" -B "$SRC/build-mobileglues" "${IOS_ARGS[@]}" -DMACOS=1 \
  -DCMAKE_C_FLAGS="$MG_DIAG_FLAGS" -DCMAKE_CXX_FLAGS="$MG_DIAG_FLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-rpath,@executable_path/Frameworks"
"$CMAKE" --build "$SRC/build-mobileglues" -j "$JOBS" --target mobileglues

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$SRC/build-mobileglues/libmobileglues.dylib" "$OUT/"
cp "$CROSS" "$OUT/$(otool -D "$CROSS" | tail -1 | sed 's|.*/||')"
# CMake also records the build-tree library dir as an rpath; drop it.
install_name_tool -delete_rpath "$LIBDIR" "$OUT/libmobileglues.dylib" 2>/dev/null || true
for f in "$OUT"/*.dylib; do
  platform=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
  [ "$platform" = "2" ] || { echo "$f is not an iOS binary (platform $platform)" >&2; exit 1; }
done
echo "MobileGlues $MG_REV, glslang $GLSLANG_TAG, SPIRV-Cross $SPIRV_CROSS_TAG"
ls -la "$OUT"
otool -L "$OUT/libmobileglues.dylib"
# Nothing from FastSTL may ship (see patch 0002).
if nm -C "$OUT/libmobileglues.dylib" 2>/dev/null | grep -c "FastSTL::" >/dev/null; then
  echo "FastSTL code found in libmobileglues.dylib" >&2; exit 1
fi
echo "FastSTL: none in libmobileglues.dylib"
# glMultiDrawArrays (patch 0004) must be exported with its C name for LWJGL.
EXPORTS="$(nm -gU "$OUT/libmobileglues.dylib")"   # (no grep -q on a pipe: SIGPIPE + pipefail)
for sym in _glMultiDrawArrays _glColorMaski; do
  case "$EXPORTS" in *" $sym"*) ;; *) echo "$sym not exported" >&2; exit 1 ;; esac
done
