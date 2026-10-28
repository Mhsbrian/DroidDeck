#!/usr/bin/env bash
# Milestone 0 on an x86_64 Android device over adb: x86_64 proot, then RADV and NVIDIA's driver inside it.
set -euo pipefail
usage() { echo "usage: [NDK=...] [ADB_BIN=adb] $0 --serial SERIAL [--nvidia-run NVIDIA-Linux-x86_64-VER.run] [--keep]" >&2; exit 2; }
SERIAL= NVRUN= KEEP=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --serial) SERIAL=$2; shift 2 ;;
    --nvidia-run) NVRUN=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) usage ;;
  esac
done
[[ -n $SERIAL ]] || usage
: "${NDK:?set NDK to the Android NDK root}"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${DROIDDECK_M0_OUT:-$HERE/../../build/googlebook-m0}
DEV=/data/local/tmp/droiddeck-m0
ADB=("${ADB_BIN:-adb}" -s "$SERIAL")
mkdir -p "$OUT/ctx/nvidia"

DROIDDECK_ABI=x86_64 bash "$HERE/../proot/build.sh" "$OUT/proot" >"$OUT/proot-build.log" 2>&1

rm -rf "$OUT/ctx/nvidia"/* "$OUT/nvidia-extract"
if [[ -n $NVRUN ]]; then
  sh "$NVRUN" --extract-only --target "$OUT/nvidia-extract" >/dev/null
  v=$(basename "$NVRUN" .run | sed 's/.*-//')
  for f in libGLX_nvidia libEGL_nvidia libnvidia-glcore libnvidia-eglcore libnvidia-glsi libnvidia-tls libnvidia-gpucomp \
           libnvidia-glvkspirv libnvidia-rtcore libnvidia-allocator; do
    cp "$OUT/nvidia-extract/$f.so.$v" "$OUT/ctx/nvidia/"
  done
  cp "$OUT/nvidia-extract"/{libnvidia-egl-gbm.so.1.1.3,nvidia_icd.json,nvidia_layers.json,10_nvidia.json,15_nvidia_gbm.json} "$OUT/ctx/nvidia/"
fi
cp "$HERE/m0.Dockerfile" "$OUT/ctx/Dockerfile"
cp "$HERE/vkprobe.c" "$OUT/ctx/"
docker build -q -t droiddeck-googlebook-m0 "$OUT/ctx" >/dev/null
cid=$(docker create droiddeck-googlebook-m0)
docker export "$cid" | gzip -1 >"$OUT/rootfs.tar.gz"
docker rm "$cid" >/dev/null
sha256sum "$OUT"/proot/*.so "$OUT/rootfs.tar.gz" | tee "$OUT/SHA256SUMS"

"${ADB[@]}" shell "rm -rf $DEV && mkdir -p $DEV/rootfs $DEV/tmp"
"${ADB[@]}" push "$OUT"/proot/*.so "$OUT/rootfs.tar.gz" "$DEV/" >/dev/null
# Android denies hard links to apps and to adb; the few hard-linked files are not needed here.
"${ADB[@]}" shell "cd $DEV && chmod 755 libproot*.so && tar -xzf rootfs.tar.gz -C rootfs 2>/dev/null; rm rootfs.tar.gz"

cat >"$OUT/run.sh" <<SH
D=$DEV
export PROOT_LOADER=\$D/libproot-loader.so PROOT_LOADER_32=\$D/libproot-loader32.so PROOT_TMP_DIR=\$D/tmp
run() { \$D/libproot.so -0 --link2symlink -r \$D/rootfs -b \$D/rootfs:\$D/rootfs -b /dev -b /proc -b /sys -w /root \
  /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root XDG_RUNTIME_DIR=/tmp "\$@"; }
echo "== proot"; t0=\$(date +%s%N)
run /bin/sh -c 'uname -m; . /etc/os-release; echo \$PRETTY_NAME; i=0; while [ \$i -lt 2000 ]; do [ -e /usr/bin/env ]; i=\$((i+1)); done; echo ok'
echo "elapsed_ms=\$(( (\$(date +%s%N) - t0) / 1000000 ))"
echo "== devices"; run vulkaninfo --summary 2>&1 | grep -E 'deviceName|driverID|driverInfo|conformanceVersion'
for v in 1002 10de; do echo "== vkprobe \$v"; run vkprobe \$v 2>&1; done
echo "== vkmark radeon"; run VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json vkmark --winsys headless -s 1920x1080 \
  -b vertex:duration=5 -b texture:duration=5 -b shading:shading=phong:duration=5 -b cube:duration=5 \
  -b effect2d:kernel=edge:duration=5 -b desktop:duration=5 2>&1 | grep -E '^\[|Score'
SH
"${ADB[@]}" push "$OUT/run.sh" "$DEV/run.sh" >/dev/null
{
  echo "device: $("${ADB[@]}" shell getprop ro.build.fingerprint)"
  echo "abilist: $("${ADB[@]}" shell getprop ro.product.cpu.abilist)"
  "${ADB[@]}" shell "sh $DEV/run.sh"
} | tee "$OUT/m0-result.txt"
[[ $KEEP == 1 ]] || "${ADB[@]}" shell "rm -rf $DEV"
