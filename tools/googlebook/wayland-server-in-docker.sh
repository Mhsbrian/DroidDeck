set -euo pipefail
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  ca-certificates curl xz-utils make meson ninja-build pkg-config patchelf gcc libc6-dev libexpat1-dev >/dev/null
. /tools/wayland-server.env
API=26 W=/work SYS=/work/sysroot
mkdir -p $W && cd $W
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; echo "$3  $2" | sha256sum -c -; }
fetch "$LIBFFI_URL" libffi.tar.gz "$LIBFFI_SHA256"
fetch "$WAYLAND_URL" wayland.tar.xz "$WAYLAND_SHA256"
tar xf libffi.tar.gz && tar xf wayland.tar.xz
meson setup build-scanner wayland-$WAYLAND_VERSION --prefix=/usr/local --buildtype=release \
  -Dlibraries=false -Dscanner=true -Ddocumentation=false -Ddtd_validation=false -Dtests=false >/dev/null
ninja -C build-scanner install >/dev/null
TC=/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
export CC=$TC/$TRIPLE$API-clang AR=$TC/llvm-ar RANLIB=$TC/llvm-ranlib STRIP=$TC/llvm-strip
LDF="-Wl,-z,max-page-size=16384"
(cd libffi-$LIBFFI_VERSION && LDFLAGS="$LDF" ./configure --host=$TRIPLE --prefix=$SYS --disable-static --disable-docs \
  --disable-multi-os-directory >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null)
cat >cross.txt <<CROSS
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'
[built-in options]
c_link_args = ['$LDF']
[properties]
pkg_config_libdir = '$SYS/lib/pkgconfig'
[host_machine]
system = 'android'
cpu_family = '$CPU'
cpu = '$CPU'
endian = 'little'
CROSS
PKG_CONFIG_PATH_FOR_BUILD=/usr/local/lib64/pkgconfig meson setup build-wl wayland-$WAYLAND_VERSION --cross-file cross.txt --prefix=$SYS --buildtype=release \
  -Dlibraries=true -Dscanner=false -Ddocumentation=false -Ddtd_validation=false -Dtests=false >/dev/null
ninja -C build-wl >/dev/null
cp -L $SYS/lib/libffi.so /out/libffi.so
cp -L build-wl/src/libwayland-server.so /out/libwayland-server.so
patchelf --set-soname libffi.so /out/libffi.so
patchelf --set-soname libwayland-server.so --replace-needed "$(patchelf --print-needed /out/libwayland-server.so | grep libffi)" libffi.so /out/libwayland-server.so
$STRIP --strip-unneeded /out/libffi.so /out/libwayland-server.so
chown "$HOST_UID:$HOST_GID" /out/*.so
