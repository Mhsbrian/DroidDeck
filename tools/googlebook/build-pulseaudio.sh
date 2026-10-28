#!/usr/bin/env bash
# Builds the Android-side PulseAudio 13 (daemon, libraries, pactl, modules) with libltdl and libsndfile for one ABI, in Docker.
# Output: <out>/lib (for app/src/main/jniLibs/<abi>), <out>/bundle (pactl and modules/<abi>), <out>/src (PulseAudio headers for the sinks).
set -euo pipefail
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
: "${NDK:?set NDK to the Android NDK root}"
HERE=$(cd "$(dirname "$0")" && pwd)
ABI=${DROIDDECK_ABI:-x86_64}
case "$ABI" in
  x86_64) TRIPLE=x86_64-linux-android CPU=x86_64 ;;
  arm64-v8a) TRIPLE=aarch64-linux-android CPU=aarch64 ;;
  *) echo "Unsupported DROIDDECK_ABI: $ABI" >&2; exit 1 ;;
esac
docker run --rm --platform linux/amd64 -v "$NDK":/ndk:ro -v "$HERE":/tools:ro -v "$OUT":/out \
  -e ABI="$ABI" -e TRIPLE="$TRIPLE" -e CPU="$CPU" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  ubuntu:24.04 bash /tools/pulseaudio-in-docker.sh
