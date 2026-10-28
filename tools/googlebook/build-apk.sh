#!/usr/bin/env bash
# Builds the Googlebook x86_64 APK: native inputs, the PulseAudio bundle, the DirectAudio relay, Rust, Gradle, then the owner's signature.
# Needs Docker, JDK 17, the Android SDK and NDK, rustup with x86_64-linux-android and cargo-ndk.
set -euo pipefail
usage() { echo "usage: NDK=... ANDROID_HOME=... GOOGLEBOOK_KEYSTORE=... GOOGLEBOOK_KEYSTORE_PASS_FILE=... $0 <out.apk> [debug|release]" >&2; exit 2; }
[[ $# -ge 1 ]] || usage
OUT_APK=$(realpath -m "$1")
TYPE=${2:-release}
: "${NDK:?}" "${ANDROID_HOME:?}" "${GOOGLEBOOK_KEYSTORE:?}" "${GOOGLEBOOK_KEYSTORE_PASS_FILE:?}"
ABI=x86_64
REPO=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${DROIDDECK_GOOGLEBOOK_WORK:-$REPO/build/googlebook-$ABI}
LIBS=$REPO/app/src/main/jniLibs/$ABI
mkdir -p "$WORK" "$LIBS"
export DROIDDECK_ABI=$ABI

[[ -f $LIBS/libwayland-server.so && -f $LIBS/libffi.so ]] || "$REPO/tools/googlebook/build-wayland-server.sh" "$LIBS"

"$REPO/tools/googlebook/build-pulseaudio.sh" "$WORK/pulseaudio"
cp "$WORK"/pulseaudio/lib/*.so "$LIBS/"
"$REPO/tools/aaudio-sink/build.sh" "$WORK/pulseaudio/src" "$WORK/pulseaudio/bundle/modules/$ABI"
mkdir -p "$REPO/app/build/prepared-assets-$ABI"
# The session preloads (System V IPC for Steam's tier0, the controller reader) as x86_64 builds, at the paths the
# arm64 build uses for its own; glibc 2.31 keeps them loadable in Steam Linux Runtime 3.0.
docker run --rm --platform linux/amd64 -v "$REPO":/src:ro -v "$WORK":/out -w /src -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  debian:bullseye sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    gcc g++ gcc-multilib g++-multilib binutils >/dev/null && sh tools/linuxfs/build-x86-preloads.sh /out/preloads &&
    chown -R "$HOST_UID:$HOST_GID" /out/preloads'
mkdir -p "$REPO/app/build/prepared-assets-$ABI/linuxfs"
cp "$WORK/preloads/x86_64/libblsession.so" "$WORK/preloads/x86_64/libfakeinput.so" "$REPO/app/build/prepared-assets-$ABI/linuxfs/"
tar -C "$WORK/pulseaudio/bundle" --owner=0 --group=0 --sort=name -cf - . | zstd -19 -q -f -o "$REPO/app/build/prepared-assets-$ABI/pulseaudio.tzst"

. "$REPO/tools/directaudio/release.env"
src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
curl -fsSL --retry 3 -o "$src/source.tar.gz" "https://github.com/${DIRECTAUDIO_REPO}/archive/${DIRECTAUDIO_SOURCE_COMMIT}.tar.gz"
echo "${DIRECTAUDIO_SOURCE_SHA256}  $src/source.tar.gz" | sha256sum -c - >/dev/null
mkdir "$src/source" && tar -xzf "$src/source.tar.gz" --strip-components=1 -C "$src/source"
"$REPO/tools/directaudio/build-relay.sh" "$REPO" "$src/source"

task=assembleRelease apk=$REPO/app/build/outputs/apk/release/app-release.apk
[[ $TYPE == debug ]] && task=assembleDebug apk=$REPO/app/build/outputs/apk/debug/app-debug.apk
ndk_version=$(basename "$NDK")
(cd "$REPO" && ./gradlew --no-daemon -PdroiddeckAbi=$ABI -PndkVersion="$ndk_version" ":app:$task")
"$REPO/tools/googlebook/sign-apk.sh" "$apk" "$OUT_APK"
sha256sum "$OUT_APK"
