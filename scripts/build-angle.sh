#!/usr/bin/env bash
# Builds ANGLE (OpenGL ES on Metal) for iOS arm64 devices from source into
# build/deps/angle/out/ios-arm64. The Xcode build copies libEGL/libGLESv2
# into the app (see the "Bundle ANGLE" build phase).
#
# Recipe and gn args follow AngelAuraMC/angle (fcl/angle branch,
# out/ios-arm64/args.gn and .github/workflows/build.yml), applied to upstream
# https://chromium.googlesource.com/angle/angle.git. Needs Xcode, git,
# python3, network access, and several GB of free disk.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
ANGLE="$DEPS/angle"
OUT="out/ios-arm64"
# Upstream ANGLE commit to build (override with ANGLE_REV=...).
ANGLE_REV="${ANGLE_REV:-33f8caff4b77667bc50d8484401af01291de119d}"  # revision checked out on 2026-10-16

mkdir -p "$DEPS"
if [ ! -d "$DEPS/depot_tools" ]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPS/depot_tools"
fi
export PATH="$DEPS/depot_tools:$PATH" DEPOT_TOOLS_METRICS=0 DEPOT_TOOLS_UPDATE=0

mkdir -p "$ANGLE"
cd "$ANGLE"
if [ ! -f .gclient ]; then
  gclient config --spec 'solutions = [
  {
    "name": ".",
    "url": "https://chromium.googlesource.com/angle/angle.git",
    "deps_file": "DEPS",
    "managed": False,
    "custom_vars": {},
  },
]
target_os = ["ios"]'
fi
if [ -n "$ANGLE_REV" ]; then
  gclient sync -Rf --no-history --with_branch_heads --revision ".@$ANGLE_REV"
else
  gclient sync -Rf --no-history --with_branch_heads
fi

mkdir -p "$OUT"
cat > "$OUT/args.gn" <<'GN'
target_os = "ios"
target_cpu = "arm64"
target_environment = "device"
ios_enable_code_signing = false
is_component_build = false
is_debug = false
symbol_level = 0
angle_standalone = false
angle_build_tests = false
build_angle_deqp_tests = false
angle_build_all = false
angle_has_frame_capture = false
angle_expose_non_conformant_extensions_and_versions = true
angle_enable_gl = false
angle_enable_d3d11 = false
angle_enable_null = false
angle_enable_vulkan = false
angle_enable_wgpu = false
angle_enable_swiftshader = false
angle_enable_metal = true
angle_enable_essl = true
angle_enable_glsl = true
GN
if [ -n "${ANGLE_EXTRA_GN_ARGS:-}" ]; then
  printf '%s\n' "$ANGLE_EXTRA_GN_ARGS" >> "$OUT/args.gn"
fi

"$DEPS/depot_tools/ensure_bootstrap" >/dev/null
gn gen "$OUT"
autoninja -C "$OUT" libEGL libGLESv2

echo "ANGLE revision: $(git -C "$ANGLE" rev-parse HEAD)"
ls -la "$OUT" | grep -E "libEGL|libGLESv2" || true
