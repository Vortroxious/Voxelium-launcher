#!/usr/bin/env bash
# Gathers the licence texts of every third-party component in the IPA into
# THIRD_PARTY_NOTICES.txt (repo root) and App/Voxelium/Resources/ (shipped in
# the app and shown under Settings → About & licences). Run after the build-*.sh
# scripts, which leave the sources in build/deps. Fails if a licence file is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
OUT="$ROOT/THIRD_PARTY_NOTICES.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

section() {   # title, licence summary, file...
  local title="$1" summary="$2"; shift 2
  {
    printf '\n%s\n%s\n%s\n\n' "================================================================================" "$title" "$summary"
    for f in "$@"; do
      [ -f "$f" ] || { echo "missing licence file: $f" >&2; exit 1; }
      cat "$f"; printf '\n'
    done
  } >> "$OUT"
}

# libffi licences come from the release tarballs build-lwjgl.sh used.
for v in 3.4.8 3.5.2; do
  tar -xzf "$DEPS/libffi-dl/libffi-$v.tar.gz" -C "$TMP" "libffi-$v/LICENSE"
done
# stb and tinyfiledialogs carry their licences in their source headers.
STB_H="$(find "$DEPS/lwjgl3/modules/lwjgl/stb" -name 'stb_image.h' | head -1)"
TINYFD_C="$(find "$DEPS/lwjgl3/modules/lwjgl/tinyfd" -name 'tinyfiledialogs.c' | head -1)"
[ -n "$STB_H" ] && [ -n "$TINYFD_C" ] || { echo "stb or tinyfiledialogs source not found" >&2; exit 1; }
tail -n 40 "$STB_H" > "$TMP/stb-license.txt"
sed -n '1,/\*\//p' "$TINYFD_C" > "$TMP/tinyfd-license.txt"
# LWJGL 3.4.3 (Minecraft 26.3) is optional for now: its notices are added only when
# LWJGL_SERIES=3.4.3 scripts/build-lwjgl.sh has run (the app bundles it only then).
LW43=""
if [ -d "$DEPS/lwjgl-out-3.4.3/natives" ]; then
  LW43="$DEPS/lwjgl3-3.4.3"
  tar -xzf "$DEPS/libffi-dl/libffi-3.8.0.tar.gz" -C "$TMP" "libffi-3.8.0/LICENSE"
  # VMA carries its MIT licence in its header.
  sed -n '1,/^$/p' "$LW43/modules/lwjgl/vma/src/main/c/vk_mem_alloc.h" | sed 's|^// \{0,1\}||' > "$TMP/vma-license.txt"
  [ -f "$DEPS/shaderc-out/libshaderc_shared.dylib" ] || { echo "LWJGL 3.4.3 is built but shaderc is not; run scripts/build-shaderc.sh" >&2; exit 1; }
fi

cat > "$OUT" <<'EOF'
Voxelium — third-party notices

Voxelium is free software under the GNU General Public License v3.0 (LICENSE).
Its source, including the patches and build scripts for every component below,
is published with each release. Minecraft is a trademark of Mojang Synergies AB;
no Minecraft game files are included (they are downloaded from Mojang).

The app bundles the following components, each under its own licence:
EOF

section "OpenJDK runtimes 8, 17, 21, 25 for iOS arm64 (AngelAuraMC builds)" \
  "GPL-2.0 with the Classpath Exception. Each runtime's legal/ folder inside the app holds its per-module notices." \
  "$ROOT/build/runtime/jre17/legal/java.base/LICENSE"
section "ANGLE (libEGL, libGLESv2), chromium.googlesource.com/angle/angle 33f8caff4b77" "BSD-3-Clause" \
  "$DEPS/angle/LICENSE"
section "abseil-cpp (in libGLESv2)" "Apache-2.0" "$DEPS/angle/third_party/abseil-cpp/LICENSE"
section "Perfetto (in libGLESv2)" "Apache-2.0" "$DEPS/angle/third_party/perfetto/LICENSE"
section "zlib (in libGLESv2)" "zlib" "$DEPS/angle/third_party/zlib/LICENSE"
section "LLVM libc++ and libc++abi (in libGLESv2, libEGL)" "Apache-2.0 WITH LLVM-exception" \
  "$DEPS/angle/third_party/libc++/src/LICENSE.TXT"
section "xxHash (in libGLESv2)" "BSD-2-Clause" "$DEPS/angle/src/common/third_party/xxhash/LICENSE"
section "MobileGlues f0fb4d32794a with Voxelium patches 0001-0014 (libmobileglues.dylib)" \
  "LGPL-2.1. Dynamically linked; source: github.com/MobileGL-Dev/MobileGlues, our changes in patches/mobileglues/, rebuild with scripts/build-mobileglues.sh." \
  "$DEPS/mg-src/MobileGlues/LICENSE"
section "glslang 15.0.0 (in libmobileglues)" "BSD-3-Clause and others, see below" "$DEPS/mg-src/glslang/LICENSE.txt"
section "SPIRV-Tools (in libmobileglues)" "Apache-2.0" "$DEPS/mg-src/glslang/External/spirv-tools/LICENSE"
section "SPIRV-Headers (in libmobileglues)" "MIT-style (Khronos)" "$DEPS/mg-src/glslang/External/spirv-tools/external/spirv-headers/LICENSE"
section "SPIRV-Cross vulkan-sdk-1.4.304.0 (libspirv-cross-c-shared.dylib)" "Apache-2.0" "$DEPS/mg-src/SPIRV-Cross/LICENSE"
section "GLM (in libmobileglues)" "MIT (or the Happy Bunny License)" "$DEPS/mg-src/MobileGlues/src/main/cpp/3rdparty/glm/copying.txt"
section "xxhash by Stephan Brumme (in libmobileglues)" "MIT" "$DEPS/mg-src/MobileGlues/src/main/cpp/3rdparty/xxhash/LICENSE"
section "gl4es (libgl4es.dylib), PojavLauncherTeam/gl4es c3d6a54f8a2c, with patches/gl4es" "MIT" "$DEPS/gl4es/LICENSE"
section "LWJGL 3.3.3 and 3.4.1 (AngelAuraMC/lwjgl3 forks)" "BSD-3-Clause" "$DEPS/lwjgl3/LICENSE.md"
section "libffi 3.4.8 (in LWJGL 3.3.3) and 3.5.2 (in LWJGL 3.4.1)" "MIT" "$TMP/libffi-3.4.8/LICENSE" "$TMP/libffi-3.5.2/LICENSE"
if [ -n "$LW43" ]; then
  SC="$DEPS/shaderc-src"
  section "LWJGL 3.4.3 (github.com/LWJGL/lwjgl3, with patches/lwjgl/3.4.3-*)" "BSD-3-Clause" "$LW43/LICENSE.md"
  section "libffi 3.8.0 (in LWJGL 3.4.3)" "MIT" "$TMP/libffi-3.8.0/LICENSE"
  section "Vulkan Memory Allocator 3.4.0 (in liblwjgl_vma)" "MIT" "$TMP/vma-license.txt"
  section "shaderc v2026.3, LWJGL-CI/shaderc LWJGL-3.4.3 (libshaderc_shared.dylib)" "Apache-2.0" "$SC/shaderc/LICENSE"
  section "glslang 16.4.0 (in libshaderc_shared)" "BSD-3-Clause and others, see below" "$SC/shaderc/third_party/glslang/LICENSE.txt"
  section "SPIRV-Tools v2026.3 (in libshaderc_shared)" "Apache-2.0" "$SC/shaderc/third_party/spirv-tools/LICENSE"
  section "SPIRV-Headers (in libshaderc_shared)" "MIT-style (Khronos)" "$SC/shaderc/third_party/spirv-headers/LICENSE"
  section "SPIRV-Cross vulkan-sdk-1.4.357.0 (libspirv-cross.dylib, for LWJGL 3.4.3)" "Apache-2.0" "$SC/SPIRV-Cross/LICENSE"
fi
section "stb (in liblwjgl_stb)" "MIT or public domain" "$TMP/stb-license.txt"
section "tinyfiledialogs (in liblwjgl_tinyfd)" "zlib" "$TMP/tinyfd-license.txt"
section "FreeType 2.13.3 (libfreetype.dylib)" \
  "FreeType License (FTL), chosen from its FTL/GPL-2.0 dual licence. Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved." \
  "$DEPS/freetype/docs/FTL.TXT"
section "OpenAL Soft 1.25.2 (libopenal.dylib)" "LGPL-2.0 or later. Dynamically linked; source: github.com/kcat/openal-soft, rebuild with scripts/build-openal.sh." \
  "$DEPS/openal-soft/COPYING"
section "UniversalJIT26.js and UniversalJIT26Extension.js (Amethyst-iOS); JIT helpers in JITSupport.m adapted from Amethyst-iOS" \
  "GPL-3.0, the same licence as Voxelium (see LICENSE)." "$ROOT/LICENSE"

cp "$OUT" "$ROOT/App/Voxelium/Resources/THIRD_PARTY_NOTICES.txt"
echo "wrote $OUT ($(wc -l < "$OUT") lines) and App/Voxelium/Resources/THIRD_PARTY_NOTICES.txt"
