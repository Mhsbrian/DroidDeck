#!/usr/bin/env bash
set -euo pipefail
repo_root=$1
source_dir=$2
: "${NDK:=${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}}"
: "${NDK:?set NDK to the Android NDK root}"
case "$(uname -s)" in
  Darwin) host=darwin-x86_64 ;;
  Linux) host=linux-x86_64 ;;
  *) echo 'Unsupported NDK host' >&2; exit 1 ;;
esac
toolchain="$NDK/toolchains/llvm/prebuilt/$host/bin"
abi=${DROIDDECK_ABI:-arm64-v8a}
case "$abi" in
  arm64-v8a) triple=aarch64-linux-android ;;
  x86_64) triple=x86_64-linux-android ;;
  *) echo "Unsupported DROIDDECK_ABI: $abi" >&2; exit 1 ;;
esac
out="$repo_root/app/src/main/jniLibs/$abi/libdirectaudiorelay.so"
mkdir -p "$(dirname "$out")"
patch -d "$source_dir" -p1 < "$repo_root/tools/directaudio/microphone-toggle.patch"
"$toolchain/${triple}28-clang" -O2 -Wl,-z,max-page-size=16384 \
  "$source_dir/directaudio-relay.c" -o "$out" \
  -laaudio -llog -pthread
"$toolchain/llvm-strip" --strip-unneeded "$out"
