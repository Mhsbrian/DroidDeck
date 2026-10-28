set -euo pipefail
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  ca-certificates curl xz-utils make cmake meson ninja-build pkg-config patchelf python3 m4 perl file >/dev/null
. /tools/pulseaudio.env
# Android 13 (API 33) has glob and backtrace in bionic, which PulseAudio uses.
API=33 W=/work SYS=/work/sysroot
mkdir -p $W $SYS && cd $W
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; echo "$3  $2" | sha256sum -c -; }
fetch "$PA_URL" pa.tar.xz "$PA_SHA256"
fetch "$LIBTOOL_URL" libtool.tar.xz "$LIBTOOL_SHA256"
fetch "$SNDFILE_URL" sndfile.tar.xz "$SNDFILE_SHA256"
tar xf pa.tar.xz && tar xf libtool.tar.xz && tar xf sndfile.tar.xz
TC=/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
export CC=$TC/$TRIPLE$API-clang CXX=$TC/$TRIPLE$API-clang++ AR=$TC/llvm-ar RANLIB=$TC/llvm-ranlib STRIP=$TC/llvm-strip NM=$TC/llvm-nm
LDF="-Wl,-z,max-page-size=16384"

(cd libtool-$LIBTOOL_VERSION && LDFLAGS="$LDF" ./configure --host=$TRIPLE --prefix=$SYS --enable-ltdl-install \
  --disable-static >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null)

cmake -S libsndfile-$SNDFILE_VERSION -B build-sndfile -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=/ndk/build/cmake/android.toolchain.cmake -DANDROID_ABI=$ABI -DANDROID_PLATFORM=android-$API \
  -DCMAKE_INSTALL_PREFIX=$SYS -DBUILD_SHARED_LIBS=ON -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
  -DENABLE_EXTERNAL_LIBS=OFF -DENABLE_MPEG=OFF -DINSTALL_MANPAGES=OFF -DENABLE_CPACK=OFF \
  -DCMAKE_SHARED_LINKER_FLAGS="$LDF" >/dev/null
cmake --build build-sndfile >/dev/null && cmake --install build-sndfile >/dev/null

PA=pulseaudio-$PA_VERSION
# Android's app seccomp filter kills the set*id calls PulseAudio uses to drop root it never has, and bionic has no libcap.
python3 - "$PA/src/daemon/caps.c" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
for fn in ('pa_drop_root', 'pa_drop_caps'):
    s, n = re.subn(r'void ' + fn + r'\(void\) \{.*?\n\}\n', 'void ' + fn + '(void) {\n}\n', s, count=1, flags=re.S)
    assert n == 1, fn
open(p, 'w').write(s)
PY
sed -i 's/rlimit_nofile = { .value = 256,/rlimit_nofile = { .value = 4096,/' $PA/src/daemon/daemon-conf.c
# bionic has no gettext.
sed -i "s/^cdata.set('ENABLE_NLS', 1)/# &/" $PA/meson.build

cat >cross.txt <<CROSS
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-I$SYS/include', '-Wno-error=int-conversion', '-Wno-error=incompatible-function-pointer-types']
c_link_args = ['-L$SYS/lib', '$LDF', '-Wl,--undefined-version']
cpp_link_args = ['-L$SYS/lib', '$LDF']
[properties]
pkg_config_libdir = '$SYS/lib/pkgconfig'
[host_machine]
system = 'android'
cpu_family = '$CPU'
cpu = '$CPU'
endian = 'little'
CROSS
off_features="alsa asyncns avahi dbus fftw glib gsettings gtk jack lirc openssl orc samplerate soxr speex systemd udev x11 webrtc-aec"
off_bools="man tests bluez5 bluez5-native-headset bluez5-ofono-headset hal-compat"
opts=(-Ddatabase=simple -Dadrian-aec=true)
for o in $off_features; do opts+=("-D$o=disabled"); done
for o in $off_bools; do opts+=("-D$o=false"); done
LIBRARY_PATH=$SYS/lib meson setup build-pa $PA --cross-file cross.txt --prefix=/pa --buildtype=release "${opts[@]}"
ninja -C build-pa
DESTDIR=$W/dest ninja -C build-pa install >/dev/null

L=/out/lib B=/out/bundle M=/out/bundle/modules/$CPU
[ "$ABI" = arm64-v8a ] && M=/out/bundle/modules/arm64
rm -rf /out/lib /out/bundle /out/src && mkdir -p $L $M /out/src
D=$W/dest/pa
cp -L $SYS/lib/libltdl.so $L/libltdl.so
cp -L $SYS/lib/libsndfile.so $L/libsndfile.so
cp -L $D/lib/libpulse.so $L/libpulse.so
cp -L $D/lib/pulseaudio/libpulsecommon-$PA_VERSION.so $D/lib/pulseaudio/libpulsecore-$PA_VERSION.so $L/
cp -L $D/bin/pulseaudio $L/libpulseaudio.so
cp -L $D/bin/pactl $B/pactl
cp -L $D/lib/pulse-$PA_VERSION/modules/*.so $M/
cp -r $PA/src /out/src/src
for f in $L/*.so $B/pactl $M/*.so; do
  patchelf --remove-rpath "$f"
  for n in $(patchelf --print-needed "$f"); do
    case $n in
      libpulse.so.*) patchelf --replace-needed "$n" libpulse.so "$f" ;;
      libltdl.so.*) patchelf --replace-needed "$n" libltdl.so "$f" ;;
      libsndfile.so.*) patchelf --replace-needed "$n" libsndfile.so "$f" ;;
    esac
  done
  $STRIP --strip-unneeded "$f"
done
patchelf --set-soname libpulse.so $L/libpulse.so
patchelf --set-soname libltdl.so $L/libltdl.so
patchelf --set-soname libsndfile.so $L/libsndfile.so
chown -R "$HOST_UID:$HOST_GID" /out
