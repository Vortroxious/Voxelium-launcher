#!/usr/bin/env bash
# Builds LWJGL 3.3.3 Java jars and iOS arm64 native libraries from source into
# build/deps/lwjgl3. Uses the AngelAuraMC fork (PojavLauncher lineage), whose
# config/macos/build.xml compiles natives against the iPhoneOS SDK and whose
# generated sources are committed, so LWJGL's Kotlin generator is skipped.
# Recipe adapted from the fork's ci_build_ios.bash, without its prebuilt
# downloads (shaderc, freetype): those bindings are disabled here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
LWJGL_REPO="https://github.com/AngelAuraMC/lwjgl3.git"
LWJGL_BRANCH="wip/rebase_3.3.3"
LWJGL_REV="${LWJGL_REV:-6a564a8b4b1438699e9d7ccb42548e4ba454fd30}"
ANT_V="1.10.18"
# Published by Apache: https://downloads.apache.org/ant/binaries/apache-ant-1.10.18-bin.tar.gz.sha512
ANT_SHA512="c510d744876d8da48dabc9495b023b6ec5284a0f18b40ee50d98ce099e791ca5c73e3cd4c80d3c90d3efc03f9620be43aad0a373ed47198284f7e3373e0db2c3"
# Same minimum as the app (App/ZalithIOS.xcodeproj IPHONEOS_DEPLOYMENT_TARGET).
IOS_MIN="16.0"
# 3.4.6 (used by the fork CI) fails to assemble sysv.S with Xcode 27 clang.
LIBFFI_V="3.4.8"
# Not published by libffi; matches Homebrew's formula for 3.4.8 (homebrew-core bbd29c3e).
LIBFFI_SHA256="bc9842a18898bfacb0ed1252c4febcc7e78fa139fd27fdc7a3e30d9d9356119b"

mkdir -p "$DEPS"
cd "$DEPS"

# --- Apache Ant
if [ ! -x "apache-ant-$ANT_V/bin/ant" ]; then
  mkdir -p ant-dl
  curl -fL -o "ant-dl/apache-ant-$ANT_V-bin.tar.gz" "https://dlcdn.apache.org/ant/binaries/apache-ant-$ANT_V-bin.tar.gz"
  echo "$ANT_SHA512  ant-dl/apache-ant-$ANT_V-bin.tar.gz" | shasum -a 512 -c -
  tar -xzf "ant-dl/apache-ant-$ANT_V-bin.tar.gz"
fi
ANT="$DEPS/apache-ant-$ANT_V/bin/ant"

# --- LWJGL fork at a pinned commit
if [ ! -d lwjgl3/.git ]; then
  git clone --depth 1 --branch "$LWJGL_BRANCH" "$LWJGL_REPO" lwjgl3
fi
if [ "$(git -C lwjgl3 rev-parse HEAD)" != "$LWJGL_REV" ]; then
  git -C lwjgl3 fetch --depth 1 origin "$LWJGL_REV"
  git -C lwjgl3 checkout -q "$LWJGL_REV"
fi
cd lwjgl3
NATIVE=bin/libs/native/macos/arm64/org/lwjgl
mkdir -p "$NATIVE"

# --- libffi (static, iOS arm64) — LWJGL core links it
if [ ! -f "$NATIVE/libffi.a" ]; then
  mkdir -p "$DEPS/libffi-dl"
  TARBALL="$DEPS/libffi-dl/libffi-$LIBFFI_V.tar.gz"
  [ -f "$TARBALL" ] || curl -fL -o "$TARBALL" "https://github.com/libffi/libffi/releases/download/v$LIBFFI_V/libffi-$LIBFFI_V.tar.gz"
  echo "$LIBFFI_SHA256  $TARBALL" | shasum -a 256 -c -
  rm -rf libffi && tar -xzf "$TARBALL" && mv "libffi-$LIBFFI_V" libffi
  (
    cd libffi
    # Generate sources for iOS arm64 only (same edit as the fork's CI script).
    sed -i '.bak' -e '/\(64_platform\)/! s/build_target(ios_/#build_target(ios_/g' generate-darwin-source-and-headers.py
    python3 generate-darwin-source-and-headers.py --only-ios
    mv generate-darwin-source-and-headers.py.bak generate-darwin-source-and-headers.py
    # The Xcode project still copies the 32-bit ARM headers, which an arm64-only
    # generation does not produce; arm64 builds never include them.
    touch darwin_ios/include/ffi_armv7.h darwin_ios/include/ffitarget_armv7.h
    # The project still says iOS 8.0, which Xcode 27 rejects (supported: 15.0+).
    xcodebuild -arch arm64 -sdk iphoneos -target libffi-iOS -configuration Release \
      IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN"
  )
  cp libffi/build/Release-iphoneos/libffi.a "$NATIVE/"
fi

# Skip LWJGL's Kotlin generator: generated sources are committed in the fork.
mkdir -p bin/classes/generator bin/classes/templates/META-INF
touch bin/classes/generator/touch.txt bin/classes/templates/touch.txt bin/classes/generator/generated-touch.txt

# Bindings Minecraft 1.20.1 uses (core, glfw, jemalloc, openal, opengl, stb,
# tinyfd) plus opengles and egl for the ANGLE tests. Everything else off.
ON="egl glfw jemalloc openal opengl opengles stb tinyfd"
OFF="assimp bgfx meow remotery cuda fmod freetype harfbuzz hwloc jawt ktx libdivide llvm lmdb lwjglx lz4 meshoptimizer nanovg nfd nuklear odbc opencl openxr opus par rpmalloc shaderc spvc tinyexr vulkan xxhash yoga zstd"
ARGS=()
for b in $ON; do ARGS+=("-Dbinding.$b=true"); done
for b in $OFF; do ARGS+=("-Dbinding.$b=false"); done

# LWJGL 3.3.3 only recognises JDKs up to 21; on newer JDKs it falls back to
# "JDK 8 mode" and looks for jni.h in ${java.home}/../include. Point it at the
# real headers (JDK 8 mode also skips the optional Java 9 multi-release classes).
: "${JAVA_HOME:=$(/usr/libexec/java_home)}"
( yes || true ) | "$ANT" -Dplatform.macos=true -Dios-version-min="$IOS_MIN" -Djni.headers="$JAVA_HOME/include" "${ARGS[@]}" \
  -Dbuild.type=release/3.3.3 -Djavadoc.skip=true \
  compile compile-native release

# Only natives compiled here for iOS. The release step also downloads official
# macOS/Linux/Windows binaries from build.lwjgl.org (e.g. libglfw, libopenal,
# libjemalloc) for packaging; those are macOS builds and must not be bundled.
rm -rf "$DEPS/lwjgl-out"
mkdir -p "$DEPS/lwjgl-out/natives" "$DEPS/lwjgl-out/jars"
for lib in liblwjgl liblwjgl_opengl liblwjgl_opengles liblwjgl_stb liblwjgl_tinyfd; do
  f=$(find "$NATIVE" -name "$lib.dylib" | head -1)
  platform=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
  [ "$platform" = "2" ] || { echo "$f is not an iOS binary (platform $platform)" >&2; exit 1; }
  cp "$f" "$DEPS/lwjgl-out/natives/"
done
find bin/RELEASE -name '*.jar' ! -name '*-natives-*' ! -name '*-sources.jar' ! -name '*-javadoc.jar' -exec cp {} "$DEPS/lwjgl-out/jars/" \;
# The jars carry SHA-1s of the *official* natives the release step downloaded;
# LWJGL compares them against our iOS builds and prints a misleading
# "Incompatible Java and native library versions" error. Drop them so the
# check skips itself (Library.checkHash returns when no .sha1 is found).
for j in "$DEPS"/lwjgl-out/jars/*.jar; do
  zip -q -d "$j" 'META-INF/*.sha1' 'META-INF/*.git' >/dev/null 2>&1 || true
done
echo "LWJGL fork revision: $(git rev-parse HEAD)"
ls -la "$DEPS/lwjgl-out/natives" "$DEPS/lwjgl-out/jars"

# Java graphics smoke test (Milestone 6 step 2), compiled against these jars.
CLS="$(mktemp -d)"
J="$DEPS/lwjgl-out/jars"
javac --release 17 -cp "$J/lwjgl.jar:$J/lwjgl-egl.jar:$J/lwjgl-opengles.jar:$J/lwjgl-opengl.jar" -d "$CLS" \
  "$ROOT"/JavaTest/gles/io/github/zalithios/*.java
jar --create --file "$DEPS/lwjgl-out/zalith-glestest.jar" -C "$CLS" .
rm -rf "$CLS"
ls -la "$DEPS/lwjgl-out/zalith-glestest.jar"
