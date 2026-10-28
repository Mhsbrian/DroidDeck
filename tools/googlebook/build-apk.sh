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
