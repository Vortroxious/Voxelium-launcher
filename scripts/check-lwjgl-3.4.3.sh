#!/usr/bin/env bash
# Mac check of the LWJGL 3.4.3 build (LWJGL_SERIES=3.4.3 scripts/build-lwjgl.sh) and
# scripts/build-shaderc.sh, without a device. Our natives are iOS binaries and do not load
# on macOS, so:
#   1. Mojang's 26.3 jars + Mojang's macOS natives on the Mac's JDK (checks the harness);
#   2. our jars + Mojang's macOS natives (checks our Java build against a real 3.4.3 liblwjgl);
#   3. JNI surface: every native method in our jars has its Java_* symbol in our iOS natives,
#      as in Mojang's, and our natives export the same Java_* symbols as Mojang's;
#   4. our shaderc and SPIRV-Cross export the same C symbols as Mojang's.
# Mojang's files come from the 26.3 version JSON, each checked against its SHA-1 there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
OURS="$DEPS/lwjgl-out-3.4.3"
SC="$DEPS/shaderc-out"
REF="$DEPS/mojang-lwjgl-3.4.3"
VERSION_JSON_URL="https://piston-meta.mojang.com/v1/packages/61fff1316bd50312624a858bbb5eb18fa45208ed/26.3.json"
VERSION_JSON_SHA1="61fff1316bd50312624a858bbb5eb18fa45208ed"
: "${JAVA_HOME:=$(/usr/libexec/java_home)}"
JAVA="$JAVA_HOME/bin/java"

[ -f "$OURS/natives/liblwjgl.dylib" ] || { echo "run LWJGL_SERIES=3.4.3 scripts/build-lwjgl.sh first" >&2; exit 1; }
[ -f "$SC/libshaderc_shared.dylib" ] || { echo "run scripts/build-shaderc.sh first" >&2; exit 1; }

# --- Mojang's LWJGL 3.4.3 jars and macOS arm64 natives (flattened, as launchers extract them)
if [ ! -f "$REF/done" ]; then
  rm -rf "$REF" && mkdir -p "$REF/jars" "$REF/natives" "$REF/unpack"
  curl -fsS -o "$REF/26.3.json" "$VERSION_JSON_URL"
  echo "$VERSION_JSON_SHA1  $REF/26.3.json" | shasum -c - >/dev/null
  python3 -I -c '
import json, sys
for l in json.load(open(sys.argv[1]))["libraries"]:
    n = l["name"]
    if n.startswith("org.lwjgl:") and (n.count(":") == 2 or n.endswith(":natives-macos-arm64")):
        a = l["downloads"]["artifact"]; print(a["url"], a["sha1"])' "$REF/26.3.json" |
  while read -r url sha1; do
    f="$REF/jars/$(basename "$url")"
    curl -fsS -o "$f" "$url"
    echo "$sha1  $f" | shasum -c - >/dev/null
  done
  for j in "$REF"/jars/*-natives-macos-arm64.jar; do unzip -qo "$j" -d "$REF/unpack"; mv "$j" "$REF/"; done
  find "$REF/unpack" -name '*.dylib' -exec cp {} "$REF/natives/" \;
  touch "$REF/done"
fi

# --- 1 and 2: the smoke test
CLS="$(mktemp -d)"
trap 'rm -rf "$CLS"' EXIT
"$JAVA_HOME/bin/javac" --release 25 -cp "$REF/jars/*" -d "$CLS" "$ROOT"/JavaTest/lwjgl343/io/github/voxelium/Lwjgl343SmokeTest.java
run() {   # label, jar dir
  echo "== $1"
  "$JAVA" -XstartOnFirstThread --enable-native-access=ALL-UNNAMED --sun-misc-unsafe-memory-access=allow \
    -Dorg.lwjgl.librarypath="$REF/natives" -Dorg.lwjgl.vulkan.libname="$REF/natives/libMoltenVK.dylib" \
    -cp "$CLS:$2/*" io.github.voxelium.Lwjgl343SmokeTest
}
run "Mojang jars + Mojang macOS natives" "$REF/jars"
run "our jars + Mojang macOS natives" "$OURS/jars"

# --- 3: JNI surface
exports() { dyld_info -exports "$@" | awk 'NR > 2 && $2 ~ /^_/ { sub(/^_/, "", $2); print $2 }' | sort -u; }
exports "$OURS"/natives/*.dylib > "$CLS/ours.txt"
exports "$REF"/natives/liblwjgl*.dylib > "$CLS/mojang.txt"
echo "== JNI symbols of our jars' native methods"
"$JAVA" "$ROOT/JavaTest/lwjgl343/io/github/voxelium/JniSurfaceCheck.java" "$CLS/ours.txt" "$OURS"/jars/*.jar | tee "$CLS/ours-missing.txt" | tail -1
"$JAVA" "$ROOT/JavaTest/lwjgl343/io/github/voxelium/JniSurfaceCheck.java" "$CLS/mojang.txt" "$OURS"/jars/*.jar > "$CLS/mojang-missing.txt"
# Natives the jars declare for other platforms (Windows, Linux) are missing from Mojang's
# macOS build too; anything missing only from ours is a failure.
ONLY_OURS="$(comm -23 <(grep '^MISSING' "$CLS/ours-missing.txt") <(grep '^MISSING' "$CLS/mojang-missing.txt"))"
echo "missing from Mojang's macOS natives too (other platforms): $(grep -c '^MISSING' "$CLS/mojang-missing.txt" || true)"
[ -z "$ONLY_OURS" ] || { echo "$ONLY_OURS"; echo "FAIL: native methods without a symbol in our natives" >&2; exit 1; }
# Mojang's liblwjgl also has the JAWT (AWT embedding) natives, for lwjgl-jawt.jar: not a
# Minecraft library, and binding.jawt is off in our build.
jni() { grep '^Java_' "$1" | grep -v '^Java_org_lwjgl_system_jawt_' || true; }
DIFF="$(diff <(jni "$CLS/ours.txt") <(jni "$CLS/mojang.txt") || true)"
echo "Java_* exports (without JAWT): ours $(jni "$CLS/ours.txt" | wc -l | tr -d ' '), Mojang's $(jni "$CLS/mojang.txt" | wc -l | tr -d ' ')"
[ -z "$DIFF" ] || { echo "$DIFF"; echo "FAIL: our Java_* exports differ from Mojang's" >&2; exit 1; }

# --- 4: shaderc and SPIRV-Cross C exports
for pair in libshaderc_shared:libshaderc libspirv-cross:libspirv-cross; do
  c_exports() { exports "$1" | grep -v '^_Z'; }
  D="$(diff <(c_exports "$SC/${pair%%:*}.dylib") <(c_exports "$REF/natives/${pair#*:}.dylib") || true)"
  [ -z "$D" ] || { echo "$D"; echo "FAIL: ${pair%%:*} C exports differ from Mojang's ${pair#*:}" >&2; exit 1; }
  echo "${pair%%:*}: same $(c_exports "$SC/${pair%%:*}.dylib" | wc -l | tr -d ' ') C exports as Mojang's ${pair#*:}"
done
echo "LWJGL 3.4.3 check passed"
