#!/usr/bin/env bash
# Builds LWJGL Java jars and iOS arm64 native libraries from source.
#   scripts/build-lwjgl.sh                    # 3.3.3 -> build/deps/lwjgl-out (Minecraft up to 1.21.11)
#   LWJGL_SERIES=3.4.1 scripts/build-lwjgl.sh # 3.4.1 -> build/deps/lwjgl-out-3.4.1 (26.1 - 26.2)
# Uses the AngelAuraMC fork (PojavLauncher lineage), whose
# config/macos/build.xml compiles natives against the iPhoneOS SDK and whose
# generated sources are committed, so LWJGL's Kotlin generator is skipped.
# Recipe adapted from the fork's ci_build_ios.bash, without its prebuilt
# downloads (shaderc, freetype): those bindings are disabled here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
LWJGL_REPO="https://github.com/AngelAuraMC/lwjgl3.git"
SERIES="${LWJGL_SERIES:-3.3.3}"
case "$SERIES" in
  3.3.3)
    LWJGL_BRANCH="wip/rebase_3.3.3"
    LWJGL_REV="${LWJGL_REV:-6a564a8b4b1438699e9d7ccb42548e4ba454fd30}"
    SRCDIR="lwjgl3"; OUTDIR="$DEPS/lwjgl-out"
    # Bindings Minecraft uses (core, freetype, glfw, jemalloc, openal, opengl,
    # stb, tinyfd), opengles and egl for the ANGLE tests, and lwjglx: the fork's
    # LWJGL 2 API on top of LWJGL 3/GLFW, which Minecraft 1.12.2 and older need
    # (as in ZalithLauncher2 / Amethyst).
    ON="egl freetype glfw jemalloc lwjglx openal opengl opengles stb tinyfd"
    NATIVES="liblwjgl liblwjgl_opengl liblwjgl_opengles liblwjgl_stb liblwjgl_tinyfd"
    EXTRA=() ;;
  3.4.1)
    LWJGL_BRANCH="wip/rebase_3.4.1"
    LWJGL_REV="${LWJGL_REV:-702c2102a2876cdf67d1d57f6819fa2d458217d9}"
    SRCDIR="lwjgl3-3.4.1"; OUTDIR="$DEPS/lwjgl-out-3.4.1"
    # Minecraft 26.1 - 26.2: the 3.3.3 set plus vulkan (Java classes only; 26.2
    # lists lwjgl-vulkan, the GL renderer is used). Same flags as the fork's CI.
    ON="freetype glfw jemalloc openal opengl stb tinyfd vulkan"
    NATIVES="liblwjgl liblwjgl_opengl liblwjgl_stb liblwjgl_tinyfd"
    EXTRA=(-Djdk25=true "-Dnashorn.args=--no-deprecation-warning")
    LIBFFI_V="3.5.2"
    LIBFFI_SHA256="f3a3082a23b37c293a4fcd1053147b371f2ff91fa7ea1b2a52e335676bac82dc" ;;
  *) echo "unknown LWJGL_SERIES $SERIES (3.3.3 or 3.4.1)" >&2; exit 1 ;;
esac
ANT_V="1.10.18"
# Published by Apache: https://downloads.apache.org/ant/binaries/apache-ant-1.10.18-bin.tar.gz.sha512
ANT_SHA512="c510d744876d8da48dabc9495b023b6ec5284a0f18b40ee50d98ce099e791ca5c73e3cd4c80d3c90d3efc03f9620be43aad0a373ed47198284f7e3373e0db2c3"
# Same minimum as the app (App/ZalithIOS.xcodeproj IPHONEOS_DEPLOYMENT_TARGET).
IOS_MIN="16.0"
# libffi for 3.3.3: 3.4.6 (used by the fork CI) fails to assemble sysv.S with
# Xcode 27 clang, so 3.4.8. Not published by libffi; matches Homebrew's formula
# for 3.4.8 (homebrew-core bbd29c3e). LWJGL 3.4.x needs libffi >= 3.5
# (ffi_get_version, ffi_get_closure_size): 3.5.2 as the fork's CI, SHA-256 as
# GitHub publishes for the release asset.
LIBFFI_V="${LIBFFI_V:-3.4.8}"
LIBFFI_SHA256="${LIBFFI_SHA256:-bc9842a18898bfacb0ed1252c4febcc7e78fa139fd27fdc7a3e30d9d9356119b}"

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
if [ ! -d "$SRCDIR/.git" ]; then
  git clone --depth 1 --branch "$LWJGL_BRANCH" "$LWJGL_REPO" "$SRCDIR"
fi
if [ "$(git -C "$SRCDIR" rev-parse HEAD)" != "$LWJGL_REV" ]; then
  git -C "$SRCDIR" fetch --depth 1 origin "$LWJGL_REV"
  git -C "$SRCDIR" checkout -q "$LWJGL_REV"
fi
cd "$SRCDIR"
NATIVE=bin/libs/native/macos/arm64/org/lwjgl
mkdir -p "$NATIVE"

# --- libffi (static, iOS arm64) — LWJGL core links it
if [ ! -f "$NATIVE/libffi.a" ] || [ "$(cat "$NATIVE/libffi.version" 2>/dev/null)" != "$LIBFFI_V" ]; then
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
  echo "$LIBFFI_V" > "$NATIVE/libffi.version"
fi

# Skip LWJGL's Kotlin generator: generated sources are committed in the fork.
mkdir -p bin/classes/generator bin/classes/templates/META-INF
touch bin/classes/generator/touch.txt bin/classes/templates/touch.txt bin/classes/generator/generated-touch.txt

# Everything not in $ON is off: the known list plus any other module directory.
OFF="assimp bgfx meow remotery cuda fmod freetype harfbuzz hwloc jawt ktx libdivide llvm lmdb lz4 meshoptimizer nanovg nfd nuklear odbc opencl openxr opus par rpmalloc shaderc spvc tinyexr vulkan xxhash yoga zstd"
for d in modules/lwjgl/*/; do
  b=$(basename "$d")
  case "$b" in core*) continue ;; esac
  case " $ON $OFF " in *" $b "*) ;; *) OFF="$OFF $b" ;; esac
done
ARGS=()
for b in $ON; do ARGS+=("-Dbinding.$b=true"); done
for b in $OFF; do case " $ON " in *" $b "*) ;; *) ARGS+=("-Dbinding.$b=false") ;; esac; done

# LWJGL 3.3.3 only recognises JDKs up to 21; on newer JDKs it falls back to
# "JDK 8 mode" and looks for jni.h in ${java.home}/../include. Point it at the
# real headers (JDK 8 mode also skips the optional Java 9 multi-release classes).
: "${JAVA_HOME:=$(/usr/libexec/java_home)}"
# Java 8 class library for LWJGL's Java 8 classes. Official LWJGL releases are
# compiled against a JDK 8 rt.jar (JAVA8_HOME, --boot-class-path); compiling with
# "-source 8 -target 8" against JDK 26's library instead links Java 9+ methods
# such as ByteBuffer.position(I)Ljava/nio/ByteBuffer;, and Minecraft 1.12.2 -
# 1.16.5 on Java 8 then die with NoSuchMethodError in MemoryUtil (seen on device
# 2026-10-17). "--release 8" is no substitute: it hides sun.misc.Unsafe. The
# bundled iOS JRE 8's rt.jar is the same OpenJDK 8 class library, so use it.
RT8="$ROOT/build/runtime/jre8/lib/rt.jar"
[ -f "$RT8" ] || { echo "Java 8 rt.jar missing; run scripts/fetch-runtime.sh 8 first" >&2; exit 1; }
export JAVA8_HOME="$DEPS/jdk8-classlib"
mkdir -p "$JAVA8_HOME/jre/lib"
ln -sf "$RT8" "$JAVA8_HOME/jre/lib/rt.jar"
# Undo patches earlier versions of this script made, and recompile all Java.
git checkout -q -- build.xml config/build-definitions.xml modules/lwjgl/opengl/src/main/java/org/lwjgl/opengl/GL.java
# Our patches (patches/lwjgl/), per series.
for p in "$ROOT"/patches/lwjgl/"$SERIES"-*.patch; do
  [ -f "$p" ] || continue
  echo "applying $(basename "$p")"
  git apply "$p"
done
rm -rf bin/classes/lwjgl bin/RELEASE
# 3.3.3 does not recognise JDKs newer than 21 and builds in "JDK 8 mode", where it
# never applies the boot class path; apply it whenever JAVA8_HOME is set.
if [ "$SERIES" = "3.3.3" ]; then
  sed -i '' 's/if:set="set-boot-class-path"/if:set="env.JAVA8_HOME"/' config/build-definitions.xml
fi
# 3.4.x downloads its build tools (kotlinc, jspecify) first, as the fork's CI does.
if [ "$SERIES" != "3.3.3" ]; then ( yes || true ) | "$ANT" init; fi
( yes || true ) | "$ANT" -Dplatform.macos=true -Dios-version-min="$IOS_MIN" -Djni.headers="$JAVA_HOME/include" "${ARGS[@]}" \
  -Dbuild.type="release/$SERIES" -Djavadoc.skip=true ${EXTRA[@]+"${EXTRA[@]}"} \
  compile compile-native release

# Only natives compiled here for iOS. The release step also downloads official
# macOS/Linux/Windows binaries from build.lwjgl.org (e.g. libglfw, libopenal,
# libjemalloc) for packaging; those are macOS builds and must not be bundled.
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR/natives" "$OUTDIR/jars"
for lib in $NATIVES; do
  f=$(find "$NATIVE" -name "$lib.dylib" | head -1)
  platform=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
  [ "$platform" = "2" ] || { echo "$f is not an iOS binary (platform $platform)" >&2; exit 1; }
  cp "$f" "$OUTDIR/natives/"
done
find bin/RELEASE -name '*.jar' ! -name '*-natives-*' ! -name '*-sources.jar' ! -name '*-javadoc.jar' -exec cp {} "$OUTDIR/jars/" \;
# The jars carry SHA-1s of the *official* natives the release step downloaded;
# LWJGL compares them against our iOS builds and prints a misleading
# "Incompatible Java and native library versions" error. Drop them so the
# check skips itself (Library.checkHash returns when no .sha1 is found).
for j in "$OUTDIR"/jars/*.jar; do
  zip -q -d "$j" 'META-INF/*.sha1' 'META-INF/*.git' >/dev/null 2>&1 || true
done
# 3.4.x: drop the Java 25 classes (META-INF/versions/25) so LWJGL runs its
# libffi/Unsafe implementation, as 3.3.3 does on Java 17/21. Its Java 25 path makes
# callbacks with the FFM API, whose upcall stubs this iOS JDK 25 writes straight
# into the JIT-protected code cache: SIGBUS in UpcallStub::create from
# GLFWErrorCallback.create (Minecraft 26.1 on device, 2026-10-17). Those classes
# were also compiled as class version 70 by JDK 26 ("--release ${jdk.version}").
# Minecraft passes --sun-misc-unsafe-memory-access=allow for this path.
if [ "$SERIES" != "3.3.3" ]; then
  for j in "$OUTDIR"/jars/*.jar; do zip -q -d "$j" 'META-INF/versions/25/*' >/dev/null 2>&1 || true; done
fi
echo "LWJGL fork revision: $(git rev-parse HEAD)"
ls -la "$OUTDIR/natives" "$OUTDIR/jars"
# The test programs and compat stubs are built once, with the 3.3.3 series.
[ "$SERIES" = "3.3.3" ] || exit 0

# Java graphics smoke test (Milestone 6 step 2), compiled against these jars.
CLS="$(mktemp -d)"
J="$DEPS/lwjgl-out/jars"
javac --release 17 -cp "$J/lwjgl.jar:$J/lwjgl-egl.jar:$J/lwjgl-opengles.jar:$J/lwjgl-opengl.jar:$J/lwjgl-glfw.jar" -d "$CLS" \
  "$ROOT"/JavaTest/gles/io/github/zalithios/*.java
jar --create --file "$DEPS/lwjgl-out/zalith-glestest.jar" -C "$CLS" .
rm -rf "$CLS"
ls -la "$DEPS/lwjgl-out/zalith-glestest.jar"

# iOS compatibility stubs for macOS-only APIs Minecraft calls (JavaRuntime/ios-compat).
# --release 8: the jar is on the classpath for every Java (8, 17, 21, 25).
CLS="$(mktemp -d)"
javac --release 8 -Xlint:-options -sourcepath "$ROOT/JavaRuntime/ios-compat/compile-only" -d "$CLS" \
  "$ROOT"/JavaRuntime/ios-compat/src/ca/weblite/objc/*.java
rm -rf "$CLS/com"   # compile-only placeholders are never shipped
jar --create --file "$DEPS/lwjgl-out/zalith-ios-compat.jar" -C "$CLS" .
rm -rf "$CLS"
unzip -l "$DEPS/lwjgl-out/zalith-ios-compat.jar" | grep class
