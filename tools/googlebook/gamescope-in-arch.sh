set -euxo pipefail
VERSION=${GAMESCOPE_VERSION:-3.16.29}
cd /work
echo "Server = https://archive.archlinux.org/repos/$ARCH_SNAPSHOT/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
grep -q '^DisableSandbox' /etc/pacman.conf || sed -i 's/^\[options\]/[options]\nDisableSandbox/' /etc/pacman.conf
pacman -Syyuu --noconfirm --needed git sudo zstd binutils base-devel
id builder >/dev/null 2>&1 || useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
rm -rf pkg && mkdir pkg && cp -r patches pkg/ && chown -R builder pkg
sudo -u builder bash -c "
set -euxo pipefail
cd pkg
for rel in 1 2 3 4; do
  if git clone -q --depth 1 --branch ${VERSION}-\$rel https://gitlab.archlinux.org/archlinux/packaging/packages/gamescope.git arch 2>/dev/null; then break; fi
done
test -f arch/PKGBUILD
cd arch
grep -q '^pkgver=${VERSION}$' PKGBUILD
cp ../patches/*.patch .
PATCHES=\$(ls *.patch | sort)
{ echo; echo 'source+=('; for p in \$PATCHES; do echo \"  \$p\"; done; echo ')'; for p in \$PATCHES; do echo \"sha256sums+=('SKIP')\"; done; } >> PKGBUILD
cat >> PKGBUILD <<'PREP'

_googlebook_prepare() {
  cd \"\$srcdir/gamescope\"
  for p in \$(ls \"\$srcdir\"/*.patch | sort); do
    echo \"applying \$(basename \"\$p\")\"
    patch -p1 --no-backup-if-mismatch < \"\$p\"
  done
}
if declare -f prepare >/dev/null; then
  eval \"\$(declare -f prepare | sed 's/^prepare ()/_arch_prepare ()/')\"
  prepare() { _arch_prepare; _googlebook_prepare; }
else
  prepare() { _googlebook_prepare; }
fi
PREP
makepkg -s --noconfirm --skipchecksums --skippgpcheck
meson test -C src/build --no-rebuild --print-errorlogs cursor_routing wayland_scaling
"
rm -rf out && mkdir -p out/usr/local/bin out/usr/lib
PKG=$(ls pkg/arch/gamescope-*.pkg.tar.* | grep -v -- '-debug-' | head -1)
tar --use-compress-program=unzstd -xf "$PKG" -C out --strip-components=2 usr/bin/gamescope
mv out/gamescope out/usr/local/bin/gamescope
tar --use-compress-program=unzstd -xf "$PKG" -C out usr/lib/libVkLayer_FROG_gamescope_wsi_x86_64.so
strip --strip-unneeded out/usr/local/bin/gamescope out/usr/lib/libVkLayer_FROG_gamescope_wsi_x86_64.so
(cd out && tar --owner=0 --group=0 --use-compress-program='zstd -19' -cf ../gamescope-x86_64.tzst usr)
sha256sum gamescope-x86_64.tzst | tee gamescope-x86_64.tzst.sha256
chown -R "$HOST_UID:$HOST_GID" /work
