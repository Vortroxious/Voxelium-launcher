#!/usr/bin/env bash
# Feasibility spike (docs/COMPUTE_SHADERS_RESEARCH.md): builds Mesa's Zink
# (desktop OpenGL on Vulkan, MIT) for iOS arm64 devices into
# build/deps/zink-out/$ZINK_VK, with one of two Vulkan drivers under it:
#   ZINK_VK=kosmickrisp (default)  Mesa's own Vulkan-on-Metal driver, ported to
#                                  iOS by patches/mesa/ (upstream is macOS only)
#   ZINK_VK=moltenvk               MoltenVK (Apache-2.0), the last resort
# Nothing here is used by the shipping app. Only the experimental IPA
# (scripts/build-ipa-zink-experimental.sh) bundles the output.
#
# Stages: tools (host toolchain), native (host mesa_clc/vtn_bindgen2), ios
# (the cross build). With no argument all three run; each is skipped when
# its output already exists.
#
# Host toolchain: micromamba with pinned conda-forge packages (LLVM/Clang,
# libclc, SPIRV-LLVM-Translator, SPIRV-Tools, meson, ninja, bison, flex), so no
# Homebrew is needed. They run only at build time (Mesa compiles its OpenCL C
# helper kernels to NIR with them); none of them is bundled.
set -euo pipefail

ROOT="${VOXELIUM_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
DEPS="$(cd "$ROOT/build/deps" && pwd -P)"   # real path: build/ may be a symlink in a worktree
TOOLS="$DEPS/mesa-tools"
ENV="$TOOLS/env"
SRC="$DEPS/mesa-src"
ZINK_VK="${ZINK_VK:-kosmickrisp}"
OUT="$DEPS/zink-out/$ZINK_VK"
# KosmicKrisp is Metal 4 only (iOS 26+), and Mesa links with -no_weak_imports, so
# these dylibs target iOS 26 even though the app itself supports iOS 16.
IOS_MIN="26.0"

MESA_REV="9b3209540c0c229e4f366faca32a27740c9e300a"   # main on 2026-10-22 (27.0.0-devel)
MICROMAMBA_V="2.9.0-0"
LLVM_V="22.1"     # resolved versions are printed by the tools stage
LLVMSPIRV_V="22.1"
CONDA_PKGS=(
  "python=3.12" "llvmdev=$LLVM_V" "clangdev=$LLVM_V" "libclc=$LLVM_V"
  "libllvmspirv=$LLVMSPIRV_V" "spirv-tools=2026.4" "meson=1.12.1" "ninja=1.13.2"
  "pkg-config=0.29.2" "bison=3.8.2" "flex=2.6.4" "mako=1.4.3" "pyyaml=6.0.3"
  "packaging=26.3" "glslang=16.6.0" "expat"
)

JOBS="$(sysctl -n hw.ncpu)"
STAGE="${1:-all}"
case "$ZINK_VK" in kosmickrisp|moltenvk) ;; *) echo "ZINK_VK must be kosmickrisp or moltenvk" >&2; exit 2 ;; esac

# Clone `url` at `rev` into `dir`, shallowly (as in build-mobileglues.sh).
fetch() {
  local url="$1" rev="$2" dir="$3"
  if [ ! -d "$dir/.git" ]; then
    git init -q "$dir"
    git -C "$dir" remote add origin "$url"
  fi
  git -C "$dir" fetch -q --depth 1 origin "$rev"
  git -C "$dir" checkout -q -f FETCH_HEAD
}

# --- tools: micromamba (official release, SHA-256 from its .sha256 asset) + env
stage_tools() {
  local mm="$TOOLS/micromamba"
  if [ ! -x "$mm" ]; then
    mkdir -p "$TOOLS/dl"
    (
      cd "$TOOLS/dl"
      local base="https://github.com/mamba-org/micromamba-releases/releases/download/$MICROMAMBA_V"
      curl -fLo micromamba-osx-arm64 "$base/micromamba-osx-arm64"
      curl -fLo micromamba-osx-arm64.sha256 "$base/micromamba-osx-arm64.sha256"
      echo "$(cat micromamba-osx-arm64.sha256 | awk '{print $1}')  micromamba-osx-arm64" | shasum -a 256 -c -
    )
    install -m 755 "$TOOLS/dl/micromamba-osx-arm64" "$mm"
  fi
  if [ ! -x "$ENV/bin/meson" ]; then
    MAMBA_ROOT_PREFIX="$TOOLS/mamba-root" "$mm" create -y -p "$ENV" \
      --override-channels -c conda-forge "${CONDA_PKGS[@]}"
    MAMBA_ROOT_PREFIX="$TOOLS/mamba-root" "$mm" clean -y -a >/dev/null || true
  fi
  "$ENV/bin/llvm-config" --version
  "$ENV/bin/meson" --version
}

fetch_mesa() {
  fetch https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_REV" "$SRC"
  local p
  for p in "$ROOT"/patches/mesa/*.patch; do
    [ -e "$p" ] || continue
    git -C "$SRC" apply "$p"
  done
}

# Tools from conda-forge come first on PATH (meson, ninja, bison, flex, llvm-config).
tool_env() {
  export PATH="$ENV/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PKG_CONFIG_PATH="$ENV/lib/pkgconfig:$ENV/share/pkgconfig"
}

# --- native: Mesa for the macOS host, only for its build-time compilers
# (mesa_clc, vtn_bindgen2, kk_clc). A cross build cannot run its own copies.
stage_native() {
  [ -x "$TOOLS/native/bin/kk_clc" ] && { echo "native tools present"; return; }
  tool_env
  rm -rf "$SRC/build-native"
  meson setup "$SRC/build-native" "$SRC" \
    --prefix "$TOOLS/native" -Dbuildtype=release \
    -Dplatforms=macos -Dgallium-drivers= -Dvulkan-drivers=kosmickrisp \
    -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Degl=disabled -Dglx=disabled \
    -Dllvm=enabled -Dshared-llvm=enabled -Dzstd=disabled \
    -Dmesa-clc=enabled -Dinstall-mesa-clc=true \
    -Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true \
    -Dc_args="-I$ENV/include" -Dcpp_args="-I$ENV/include" \
    -Dc_link_args="-Wl,-rpath,$ENV/lib" -Dcpp_link_args="-Wl,-rpath,$ENV/lib" \
    -Dbuild-tests=false
  ninja -C "$SRC/build-native" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 src/kosmickrisp/clc/kk_clc
  mkdir -p "$TOOLS/native/bin"
  cp "$SRC/build-native/src/compiler/clc/mesa_clc" "$SRC/build-native/src/compiler/spirv/vtn_bindgen2" \
     "$SRC/build-native/src/kosmickrisp/clc/kk_clc" "$TOOLS/native/bin/"
  "$TOOLS/native/bin/mesa_clc" --help >/dev/null 2>&1 || true
}

# --- mac: the same Zink + EGL + KosmicKrisp for this Mac (Metal 4, macOS 26+), and
# scripts/zink-probe.c run against it. Checks the stack before it goes to a phone;
# its results are the Mac's, not the device's.
stage_mac() {
  tool_env
  local build="$SRC/build-mac"
  export PATH="$TOOLS/native/bin:$PATH"
  if [ ! -f "$build/build.ninja" ]; then
    meson setup "$build" "$SRC" --prefix "$build/install" -Dbuildtype=release -Db_ndebug=true \
      -Dplatforms= -Dgallium-drivers=zink -Dvulkan-drivers=kosmickrisp \
      -Dopengl=true -Dgles1=disabled -Dgles2=enabled -Degl=enabled -Dglx=disabled \
      -Dllvm=disabled -Dzstd=disabled -Dexpat=disabled -Dxmlconfig=disabled \
      -Dmesa-clc=system -Dprecomp-compiler=system -Dbuild-tests=false
  fi
  ninja -C "$build"
  # Run from the build tree, whose rpaths point at each other (install does not fix them).
  /usr/bin/cc -O1 -o "$build/zink-probe" "$ROOT/scripts/zink-probe.c"
  ZINK_VULKAN_LIBRARY="$build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib" \
    "$build/zink-probe" "$build/src/egl" \
    | tee "$ROOT/build/logs/zink-mac-probe.log"
}

# --- ios: the cross build (Zink + EGL surfaceless, plus KosmicKrisp when chosen)
stage_ios() {
  tool_env
  local sdk cross="$SRC/ios-arm64.cross" build="$SRC/build-ios-$ZINK_VK"
  sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
  local clang clangxx
  clang="$(xcrun --sdk iphoneos -f clang)"
  clangxx="$(xcrun --sdk iphoneos -f clang++)"
  local flags="'-arch', 'arm64', '-isysroot', '$sdk', '-miphoneos-version-min=$IOS_MIN'"
  cat > "$cross" <<CROSS
[binaries]
c = ['$clang']
cpp = ['$clangxx']
objc = ['$clang']
ar = ['$(xcrun --sdk iphoneos -f ar)']
strip = ['$(xcrun --sdk iphoneos -f strip)']
pkg-config = ['false']

[built-in options]
c_args = [$flags]
cpp_args = [$flags]
objc_args = [$flags]
c_link_args = [$flags]
cpp_link_args = [$flags]
objc_link_args = [$flags]

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
CROSS
  local vk_args=(-Dvulkan-drivers=)
  [ "$ZINK_VK" = "kosmickrisp" ] && vk_args=(-Dvulkan-drivers=kosmickrisp)
  [ "$ZINK_VK" = "moltenvk" ] && vk_args=(-Dvulkan-drivers= "-Dmoltenvk-dir=$DEPS/moltenvk")
  # The native compilers (stage_native) stand in for the ones a cross build cannot run.
  export PATH="$TOOLS/native/bin:$PATH"
  rm -rf "$build"
  meson setup "$build" "$SRC" --cross-file "$cross" \
    --prefix "$build/install" -Dbuildtype=release -Db_ndebug=true \
    -Dplatforms= -Dgallium-drivers=zink "${vk_args[@]}" \
    -Dopengl=true -Dgles1=disabled -Dgles2=enabled -Degl=enabled -Dglx=disabled \
    -Dllvm=disabled -Dzstd=disabled -Dexpat=disabled -Dxmlconfig=disabled \
    -Dmesa-clc=system -Dprecomp-compiler=system \
    -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
    -Dbuild-tests=false -Dshader-cache=enabled
  ninja -C "$build"
  package_ios "$build"
}

# Collect what the experimental test dlopens into $OUT, with @rpath install
# names that resolve next to each other (Frameworks/zink/ in the app). Mesa's
# libEGL is renamed so it can never be mistaken for ANGLE's libEGL.framework.
package_ios() {
  local build="$1" gallium
  gallium="$(cd "$build/src/gallium/targets/dri" && ls libgallium-*.dylib | head -1)"
  rm -rf "$OUT"
  mkdir -p "$OUT/LICENSES"
  cp "$build/src/egl/libEGL.1.dylib" "$OUT/libEGL_mesa.dylib"
  cp "$build/src/gallium/targets/dri/$gallium" "$OUT/"
  # The GL entry points by name (patch 0008), for LWJGL, which dlsym()s them.
  cp "$build/src/mesa/glapi/darwin-libgl/libGL.1.dylib" "$OUT/libGL_mesa.dylib"
  install_name_tool -id @rpath/libGL_mesa.dylib "$OUT/libGL_mesa.dylib"
  install_name_tool -delete_rpath @loader_path/../../../gallium/targets/dri "$OUT/libGL_mesa.dylib" 2>/dev/null || true
  install_name_tool -add_rpath @loader_path "$OUT/libGL_mesa.dylib"
  install_name_tool -id @rpath/libEGL_mesa.dylib "$OUT/libEGL_mesa.dylib"
  install_name_tool -delete_rpath @loader_path/../gallium/targets/dri "$OUT/libEGL_mesa.dylib" 2>/dev/null || true
  install_name_tool -add_rpath @loader_path "$OUT/libEGL_mesa.dylib"
  install_name_tool -add_rpath @loader_path "$OUT/$gallium"
  if [ "$ZINK_VK" = "kosmickrisp" ]; then
    cp "$build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib" "$OUT/"
  else
    cp "$DEPS/moltenvk/libMoltenVK.dylib" "$OUT/"
    cp "$DEPS/moltenvk/LICENSE" "$OUT/LICENSES/MoltenVK-LICENSE.txt"
  fi
  local f platform
  # Unstripped copies, to symbolicate device crash reports (hs_err, .ips) exactly.
  rm -rf "$DEPS/zink-out-symbols/$ZINK_VK"
  mkdir -p "$DEPS/zink-out-symbols/$ZINK_VK"
  cp "$OUT"/*.dylib "$DEPS/zink-out-symbols/$ZINK_VK/"
  for f in "$OUT"/*.dylib; do
    strip -x "$f" 2>/dev/null || true
    platform=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
    [ "$platform" = "2" ] || { echo "$f is not an iOS binary (platform $platform)" >&2; exit 1; }
  done
  # Mesa is MIT overall; files under other licences say so in their SPDX tags,
  # and every licence text Mesa uses is in its licenses/ folder.
  cp "$SRC/docs/license.rst" "$OUT/LICENSES/mesa-license.rst"
  cp -R "$SRC/licenses" "$OUT/LICENSES/mesa-licenses"
  {
    echo "Mesa $MESA_REV with patches/mesa/:"
    (cd "$ROOT/patches/mesa" && ls *.patch)
    echo "vulkan driver: $ZINK_VK"
  } > "$OUT/LICENSES/BUILD-INFO.txt"
  ls -la "$OUT"
  for f in "$OUT"/*.dylib; do otool -L "$f" | tail -n +2; done
}

echo "stage=$STAGE vk=$ZINK_VK"
case "$STAGE" in
  tools) stage_tools ;;
  native) fetch_mesa; stage_native ;;
  mac) fetch_mesa; stage_mac ;;
  ios) fetch_mesa; stage_ios ;;
  package) package_ios "$SRC/build-ios-$ZINK_VK" ;;
  all) stage_tools; fetch_mesa; stage_native; stage_ios ;;
  *) echo "unknown stage $STAGE" >&2; exit 2 ;;
esac
