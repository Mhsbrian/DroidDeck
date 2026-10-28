#!/usr/bin/env bash
# Builds libffi.so and libwayland-server.so for one Android ABI with the NDK, in Docker, from the sources pinned in wayland-server.env.
set -euo pipefail
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
: "${NDK:?set NDK to the Android NDK root}"
HERE=$(cd "$(dirname "$0")" && pwd)
case "${DROIDDECK_ABI:-x86_64}" in
  x86_64) TRIPLE=x86_64-linux-android CPU=x86_64 ;;
  arm64-v8a) TRIPLE=aarch64-linux-android CPU=aarch64 ;;
  *) echo "Unsupported DROIDDECK_ABI: $DROIDDECK_ABI" >&2; exit 1 ;;
esac
docker run --rm --platform linux/amd64 -v "$NDK":/ndk:ro -v "$HERE":/tools:ro -v "$OUT":/out \
  -e TRIPLE="$TRIPLE" -e CPU="$CPU" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  ubuntu:24.04 bash /tools/wayland-server-in-docker.sh
ls -l "$OUT"
