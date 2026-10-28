#!/usr/bin/env bash
# Builds the Googlebook x86_64 Linux runtime (linuxfs-x86_64.tar.zst) from a dated Arch Linux archive snapshot, in Docker.
# The x86_64 proot from tools/proot goes to opt/android-host, as in upstream's runtime. GAMESCOPE_TZST (from
# build-gamescope.sh) adds the patched gamescope in /usr/local/bin and its WSI layer over Arch's.
set -euo pipefail
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
: "${NDK:?set NDK to the Android NDK root}"
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/runtime.env"
DROIDDECK_ABI=x86_64 "$HERE/../proot/build.sh" "$OUT/proot" >"$OUT/proot-build.log" 2>&1
pkgs=$(grep -v '^#' "$HERE/runtime-packages-x86_64.txt" | tr '\n' ' ')
cid=$(docker create --platform linux/amd64 "$ARCH_IMAGE" bash -c "
  set -e
  echo 'Server = https://archive.archlinux.org/repos/$ARCH_SNAPSHOT/\$repo/os/\$arch' > /etc/pacman.d/mirrorlist
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
  sed -i 's/^#\?DisableSandbox.*//; s/^\[options\]/[options]\nDisableSandbox/' /etc/pacman.conf
  pacman -Syyuu --noconfirm --needed $pkgs
  sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
  echo 'LANG=en_US.UTF-8' > /etc/locale.conf
  pacman -Q > /var/lib/googlebook-runtime-packages.txt
  rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*
")
docker start -a "$cid" >"$OUT/pacman.log" 2>&1 || { tail -30 "$OUT/pacman.log"; docker rm "$cid" >/dev/null; exit 1; }
rm -rf "$OUT/rootfs" && mkdir -p "$OUT/rootfs"
docker export "$cid" | tar -C "$OUT/rootfs" -xpf - --exclude=.dockerenv
chmod 1777 "$OUT/rootfs/tmp" "$OUT/rootfs/var/tmp"
docker rm "$cid" >/dev/null
if [[ -n ${GAMESCOPE_TZST:-} ]]; then
  zstd -dc "$GAMESCOPE_TZST" | tar -C "$OUT/rootfs" -xf -
  test -x "$OUT/rootfs/usr/local/bin/gamescope"
fi
# docker export leaves these empty; the app writes resolv.conf from Android's link at each session start.
printf '127.0.0.1 localhost\n::1 localhost\n' > "$OUT/rootfs/etc/hosts"
mkdir -p "$OUT/rootfs/opt/android-host"
install -m755 "$OUT/proot/libproot.so" "$OUT/rootfs/opt/android-host/proot"
install -m755 "$OUT/proot/libproot-loader.so" "$OUT/rootfs/opt/android-host/loader"
install -m755 "$OUT/proot/libproot-loader32.so" "$OUT/rootfs/opt/android-host/loader32"
cp "$OUT/rootfs/var/lib/googlebook-runtime-packages.txt" "$OUT/packages.txt"
if grep -qiE '^(nvidia|lib32-nvidia|libxnvctrl|egl-wayland) ' "$OUT/packages.txt" || find "$OUT/rootfs" -name 'libnvidia-*' -o -name 'libGLX_nvidia*' | grep -q .; then
  echo "NVIDIA files found in the runtime; refusing to package it" >&2; exit 1
fi
tar -C "$OUT/rootfs" --numeric-owner --owner=0 --group=0 --sort=name -cf - . | zstd -T0 -19 -q -f -o "$OUT/linuxfs-x86_64.tar.zst"
sha=$(sha256sum "$OUT/linuxfs-x86_64.tar.zst" | cut -d' ' -f1)
size=$(stat -c %s "$OUT/linuxfs-x86_64.tar.zst")
printf '{\n  "schemaVersion": 1,\n  "category": "linux-runtime",\n  "release": "linuxfs-x86_64-%s",\n  "name": "Linux runtime for Googlebook x86_64",\n  "version": "%s",\n  "url": "%s",\n  "sha256": "%s",\n  "size": %s\n}\n' \
  "$RUNTIME_VERSION" "x86_64-$RUNTIME_VERSION" "${RUNTIME_URL:-}" "$sha" "$size" > "$OUT/linuxfs-x86_64.json"
cat "$OUT/linuxfs-x86_64.json"
