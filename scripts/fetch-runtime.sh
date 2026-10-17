#!/usr/bin/env bash
# Downloads the iOS arm64 Java runtimes published by AngelAuraMC for
# Amethyst-iOS (Java 8, 17, 21, 25: every Java a vanilla version asks for),
# unpacks them into build/runtime/jre<N>, and compiles the Java smoke test into
# build/runtime/voxelium-javatest.jar. The Xcode build copies them into the app
# bundle (see the "Bundle Java runtime" build phase).
#
#   scripts/fetch-runtime.sh            # all runtimes
#   scripts/fetch-runtime.sh 17 21      # only these
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/runtime"
BASE="https://assets.angelauramc.dev/openjdk/ios-arm64"
# The publisher does not provide checksums, so these are trust-on-first-use pins:
#  17: 2026-10-15, jre17-ios-arm64-20260708-release, OpenJDK 17.0.20
#   8: 2026-10-17, jre8-ios-arm64-20260712-release,  OpenJDK 1.8.0_472
#  21: 2026-10-17, jre21-ios-arm64-20260708-release, OpenJDK 21.0.8
#  25: 2026-10-17, jre25-ios-arm64-20260710-release, OpenJDK 25.0.4
# Each libjvm is an iOS (platform 2) arm64 Mach-O with the iOS 26 JIT hooks
# (DeviceHasTXM, MirrorMappedCodeCache, brk #0x69) the app relies on.
sha_for() {
  case "$1" in
    8)  echo "${JRE8_SHA256:-d39b627dfd96ef0224da3f36641c127da875c801a06ad4beceef02bd38807c59}" ;;
    17) echo "${JRE17_SHA256:-75e19f724afb6ffc86635fcbccc43e1e8b7345f0794261c745b16678561fe76f}" ;;
    21) echo "${JRE21_SHA256:-64043966e5e67e47bd244bb1e27f52367895674699f46693703ebd9a120b73fa}" ;;
    25) echo "${JRE25_SHA256:-3686cc278ff2d394b13cc449907259596451829bab0187786264c598dd6bd888}" ;;
    *) echo "unknown Java version $1" >&2; exit 1 ;;
  esac
}

VERSIONS=("$@")
[ ${#VERSIONS[@]} -gt 0 ] || VERSIONS=(8 17 21 25)
mkdir -p "$OUT"
for V in "${VERSIONS[@]}"; do
  ZIP="$OUT/jre$V-ios-aarch64.zip"
  if [ ! -f "$ZIP" ]; then
    echo "==> downloading $BASE/jre$V-ios-aarch64.zip"
    curl -fL --retry 5 --retry-delay 5 -C - -o "$ZIP.part" "$BASE/jre$V-ios-aarch64.zip"
    mv "$ZIP.part" "$ZIP"
  fi
  SHA256="$(sha_for "$V")"
  ACTUAL=$(shasum -a 256 "$ZIP" | awk '{print $1}')
  if [ "$ACTUAL" != "$SHA256" ]; then
    echo "SHA-256 mismatch for $ZIP: expected $SHA256, got $ACTUAL" >&2
    exit 1
  fi

  echo "==> unpacking Java $V"
  WORK="$(mktemp -d)"
  unzip -q "$ZIP" -d "$WORK"
  TARBALL=$(find "$WORK" -maxdepth 2 -name "jre$V-*.tar.xz" | head -1)
  [ -n "$TARBALL" ] || { echo "no jre$V-*.tar.xz inside $ZIP" >&2; exit 1; }
  rm -rf "$OUT/jre$V"
  mkdir -p "$OUT/jre$V"
  tar -xJf "$TARBALL" -C "$OUT/jre$V"
  rm -rf "$WORK"
  [ -f "$OUT/jre$V/lib/server/libjvm.dylib" ] || { echo "libjvm.dylib missing after unpack (Java $V)" >&2; exit 1; }
  grep -E '^(JAVA_VERSION|OS_NAME|OS_ARCH)=' "$OUT/jre$V/release" || true
  du -sh "$OUT/jre$V"
done

echo "==> compiling Java smoke test (--release 17)"
CLS="$(mktemp -d)"
javac --release 17 -d "$CLS" "$ROOT"/JavaTest/src/io/github/voxelium/*.java
jar --create --file "$OUT/voxelium-javatest.jar" -C "$CLS" .
rm -rf "$CLS"

