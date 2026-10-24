#!/usr/bin/env bash
# Builds the two shader libraries LWJGL 3.4.3 binds (Minecraft 26.3's Vulkan
# renderer) for iOS arm64, from source, into build/deps/shaderc-out:
#
# - libshaderc_shared.dylib (lwjgl-shaderc): Google shaderc v2026.3 as LWJGL
#   builds it, from LWJGL-CI/shaderc tag LWJGL-3.4.3. That fork's CMake folds
#   glslang 16.4.0 and SPIRV-Tools v2026.3 (the revisions its DEPS pins) into
#   the one library and exports their C APIs too: lwjgl-shaderc's GLSLang, Spv
#   and SpvOptimizer classes look their functions up in the shaderc library.
#   Load it with -Dorg.lwjgl.shaderc.libname (LWJGL's default name is libshaderc).
# - libspirv-cross.dylib (lwjgl-spvc): the SPIRV-Cross C API 0.68 at
#   vulkan-sdk-1.4.357.0, the upstream commit LWJGL-CI/SPIRV-Cross tag LWJGL-3.4.3
#   builds. LWJGL's default name for it, but with install name
#   @rpath/libspirv-cross.dylib: MobileGlues links its own SPIRV-Cross (C API
#   0.64) as @rpath/libspirv-cross-c-shared.0.dylib, which is also the install
#   name SPIRV-Cross gives this build, and the two must not be confused.
#
# Same CMake and source fetching as scripts/build-mobileglues.sh; the glslang and
# SPIRV-Tools there are older (15.0.0) and stay MobileGlues' own.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
SRC="$DEPS/shaderc-src"
OUT="$DEPS/shaderc-out"
IOS_MIN="16.0"

CMAKE_V="4.4.4"
CMAKE="$DEPS/cmake-$CMAKE_V-macos-universal/CMake.app/Contents/bin/cmake"
SHADERC_REV="b85bc9ae86c171e08af56ab647f8cd83bfe12d89"        # LWJGL-CI/shaderc LWJGL-3.4.3 (shaderc v2026.3)
GLSLANG_REV="168d452a4f460d24b588fed08477a81c44ee27a1"        # 16.4.0, shaderc DEPS
SPIRV_TOOLS_REV="b707790a898e44038547df54580022fc1cf89c3d"    # v2026.3, shaderc DEPS
SPIRV_HEADERS_REV="29981f65241605e08b0ede4cfeb999fe3b723c6a"  # shaderc DEPS
SPIRV_CROSS_TAG="vulkan-sdk-1.4.357.0"                        # 6c09849f, C API 0.68

JOBS="$(sysctl -n hw.ncpu)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

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
fetch https://github.com/LWJGL-CI/shaderc.git "$SHADERC_REV" "$SRC/shaderc"
fetch https://github.com/KhronosGroup/glslang.git "$GLSLANG_REV" "$SRC/shaderc/third_party/glslang"
fetch https://github.com/KhronosGroup/SPIRV-Tools.git "$SPIRV_TOOLS_REV" "$SRC/shaderc/third_party/spirv-tools"
fetch https://github.com/KhronosGroup/SPIRV-Headers.git "$SPIRV_HEADERS_REV" "$SRC/shaderc/third_party/spirv-headers"
fetch https://github.com/KhronosGroup/SPIRV-Cross.git "refs/tags/$SPIRV_CROSS_TAG" "$SRC/SPIRV-Cross"

IOS_ARGS=(
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_SYSROOT="$SDK"
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
  -DCMAKE_BUILD_TYPE=Release
)

# --- shaderc (LWJGL's CI flags, minus the tools, which iOS has no use for)
"$CMAKE" -S "$SRC/shaderc" -B "$SRC/build-shaderc" "${IOS_ARGS[@]}" \
  -DSHADERC_SKIP_INSTALL=ON -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
  -DSHADERC_SKIP_EXECUTABLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON -DSHADERC_ENABLE_WERROR_COMPILE=OFF \
  -DENABLE_GLSLANG_BINARIES=OFF -DSPIRV_SKIP_EXECUTABLES=ON -DSPIRV_WERROR=OFF
# shaderc_shared force-loads these archives (LWJGL's CMake change) without
# depending on them, so build them first.
"$CMAKE" --build "$SRC/build-shaderc" -j "$JOBS" --target glslang glslang-default-resource-limits SPIRV-Tools-static SPIRV-Tools-opt
"$CMAKE" --build "$SRC/build-shaderc" -j "$JOBS" --target shaderc_shared

# --- SPIRV-Cross C API (LWJGL's CI flags)
"$CMAKE" -S "$SRC/SPIRV-Cross" -B "$SRC/build-spirv-cross" "${IOS_ARGS[@]}" \
  -DSPIRV_CROSS_STATIC=OFF -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_CLI=OFF \
  -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_SKIP_INSTALL=ON -DSPIRV_CROSS_FORCE_PIC=ON
"$CMAKE" --build "$SRC/build-spirv-cross" -j "$JOBS" --target spirv-cross-c-shared

rm -rf "$OUT"
mkdir -p "$OUT"
cp -L "$SRC/build-shaderc/libshaderc/libshaderc_shared.dylib" "$OUT/libshaderc_shared.dylib"
cp -L "$SRC/build-spirv-cross/libspirv-cross-c-shared.dylib" "$OUT/libspirv-cross.dylib"
for f in "$OUT"/*.dylib; do
  install_name_tool -id "@rpath/$(basename "$f")" "$f"
  strip -u -r "$f"   # as LWJGL's CI: local symbols only, the exports stay
  codesign --force --sign - "$f"   # install_name_tool and strip invalidate the linker's ad-hoc signature
  platform=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
  [ "$platform" = "2" ] || { echo "$f is not an iOS binary (platform $platform)" >&2; exit 1; }
done

# The C entry points LWJGL looks up must be exported (one per API).
for pair in libshaderc_shared:_shaderc_compile_into_spv libshaderc_shared:_glslang_initialize_process \
            libshaderc_shared:_spvContextCreate libshaderc_shared:_spvOptimizerCreate \
            libspirv-cross:_spvc_context_create; do
  lib="${pair%%:*}"; sym="${pair#*:}"
  # The export trie, which dlsym reads (strip -u -r leaves nm's symbol table without them).
  EXPORTS="$(dyld_info -exports "$OUT/$lib.dylib")"   # (no grep -q on a pipe: SIGPIPE + pipefail)
  case "$EXPORTS" in *" $sym"$'\n'*|*" $sym") ;; *) echo "$sym not exported by $lib.dylib" >&2; exit 1 ;; esac
done
echo "shaderc $SHADERC_REV (glslang $GLSLANG_REV, SPIRV-Tools $SPIRV_TOOLS_REV), SPIRV-Cross $SPIRV_CROSS_TAG"
ls -la "$OUT"
otool -L "$OUT"/*.dylib
