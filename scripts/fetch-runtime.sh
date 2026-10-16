#!/usr/bin/env bash
# Downloads the iOS arm64 Java 17 runtime published by AngelAuraMC for
# Amethyst-iOS, unpacks it into build/runtime/jre17, and compiles the Java
# smoke test into build/runtime/zalith-javatest.jar. The Xcode build copies
# both into the app bundle (see the "Bundle Java runtime" build phase).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/runtime"
URL="https://assets.angelauramc.dev/openjdk/ios-arm64/jre17-ios-aarch64.zip"
# Pinned on first download (2026-10-15): the zip passed `unzip -t` and its
# inner jre17-ios-arm64-20260708-release.tar.xz unpacks to OpenJDK 17.0.20.
# The publisher does not provide a checksum, so this is trust-on-first-use.
SHA256="${JRE17_SHA256:-75e19f724afb6ffc86635fcbccc43e1e8b7345f0794261c745b16678561fe76f}"

mkdir -p "$OUT"
ZIP="$OUT/jre17-ios-aarch64.zip"
if [ ! -f "$ZIP" ]; then
  echo "==> downloading $URL"
  curl -fL --retry 5 --retry-delay 5 -C - -o "$ZIP.part" "$URL"
  mv "$ZIP.part" "$ZIP"
fi
ACTUAL=$(shasum -a 256 "$ZIP" | awk '{print $1}')
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "SHA-256 mismatch for $ZIP: expected $SHA256, got $ACTUAL" >&2
  exit 1
fi

echo "==> unpacking"
WORK="$(mktemp -d)"
unzip -q "$ZIP" -d "$WORK"
TARBALL=$(find "$WORK" -maxdepth 2 -name 'jre17-*.tar.xz' | head -1)
[ -n "$TARBALL" ] || { echo "no jre17-*.tar.xz inside $ZIP" >&2; exit 1; }
rm -rf "$OUT/jre17"
mkdir -p "$OUT/jre17"
tar -xJf "$TARBALL" -C "$OUT/jre17"
rm -rf "$WORK"
[ -f "$OUT/jre17/lib/server/libjvm.dylib" ] || { echo "libjvm.dylib missing after unpack" >&2; exit 1; }

echo "==> compiling Java smoke test (--release 17)"
CLS="$(mktemp -d)"
javac --release 17 -d "$CLS" "$ROOT"/JavaTest/src/io/github/zalithios/*.java
jar --create --file "$OUT/zalith-javatest.jar" -C "$CLS" .
rm -rf "$CLS"

grep -E '^(JAVA_VERSION|IMPLEMENTOR|OS_NAME|OS_ARCH)=' "$OUT/jre17/release" || true
du -sh "$OUT/jre17"
