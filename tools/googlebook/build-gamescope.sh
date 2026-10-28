#!/usr/bin/env bash
# Builds gamescope 3.16.29 for the x86_64 runtime with upstream's patches (minus the two for the arm64 Steam client)
# and tools/googlebook/gamescope-patches, from Arch's packaging, in Docker. Output: <out>/gamescope-x86_64.tzst.
set -euo pipefail
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
. "$HERE/runtime.env"
rm -rf "$OUT/patches" && mkdir -p "$OUT/patches"
for p in "$REPO"/tools/gamescope/patches/*.patch; do
  case $(basename "$p") in 0009-fix-arm64-steam-night-mode.patch|0019-steamcompmgr-arm64-virtual-white.patch) continue ;; esac
  cp "$p" "$OUT/patches/"
done
cp "$HERE"/gamescope-patches/*.patch "$OUT/patches/"
docker run --rm --platform linux/amd64 -v "$OUT":/work -v "$HERE/gamescope-in-arch.sh":/gamescope-in-arch.sh:ro \
  -e ARCH_SNAPSHOT="$ARCH_SNAPSHOT" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" "$ARCH_IMAGE" bash /gamescope-in-arch.sh
