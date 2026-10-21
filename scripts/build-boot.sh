#!/usr/bin/env bash
# Builds voxelium-boot.jar (JavaRuntime/voxelium-boot): the entry point Forge and
# NeoForge versions start through, which runs their installer processors in the game's
# JVM on the first launch. Java 8 bytecode, so it also runs on the bundled Java 8.
# The Xcode build copies it from build/deps/lwjgl-out into the app's java/ folder.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/deps/lwjgl-out"
CLS="$(mktemp -d)"
trap 'rm -rf "$CLS"' EXIT

mkdir -p "$OUT"
javac --release 8 -Xlint:-options -d "$CLS" "$ROOT"/JavaRuntime/voxelium-boot/src/io/github/voxelium/boot/*.java
jar --create --file "$OUT/voxelium-boot.jar" -C "$CLS" .
unzip -l "$OUT/voxelium-boot.jar" | grep class
