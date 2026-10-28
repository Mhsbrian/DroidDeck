#!/usr/bin/env bash
# Runs DroidDeck's real Steam session (droiddeck-session steam) from an x86_64 runtime image on an x86_64 Linux host,
# headless, with one AMD render node and no display node, as an Android app sees the GPU. For working on the session
# without the device. Usage: session-host-test.sh <linuxfs-x86_64.tar.zst> <work dir> [renderD node]
set -euo pipefail
RT=$1 WORK=$(mkdir -p "$2" && cd "$2" && pwd) NODE=${3:-/dev/dri/renderD128}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PRELOADS=${PRELOADS:-$REPO/build/googlebook-x86_64/preloads/x86_64}
mkdir -p "$WORK/ctx/overlay/usr/local/lib" "$WORK/home"
cp -r "$REPO/tools/linuxfs/overlay/usr" "$WORK/ctx/overlay/"
cp "$PRELOADS/libblsession.so" "$PRELOADS/libfakeinput.so" "$WORK/ctx/overlay/usr/local/lib/"
zstd -dc "$RT" | docker import - droiddeck-googlebook-runtime:test >/dev/null
cat >"$WORK/ctx/Dockerfile" <<'DOCKER'
FROM droiddeck-googlebook-runtime:test
COPY overlay/ /
# As on the device: the whole runtime belongs to the app's user, named root.
RUN chmod 755 /usr/local/bin/* && echo /usr/local/lib/libblsession.so > /etc/ld.so.preload && \
    { echo 'root:x:1000:1000::/root:/usr/bin/bash'; grep -v '^root:' /etc/passwd; } > /tmp/p && mv /tmp/p /etc/passwd && \
    { echo 'root:x:1000:'; grep -v '^root:' /etc/group; } > /tmp/g && mv /tmp/g /etc/group && chmod 644 /etc/passwd /etc/group && \
    (chown -R 1000:1000 /etc /usr /var /opt /srv /home 2>/dev/null || true)
DOCKER
docker build -q -t droiddeck-googlebook-session:test "$WORK/ctx" >/dev/null
cat >"$WORK/session.env" <<'ENV'
HOME=/root
USER=root
LANG=en_US.UTF-8
PATH=/usr/local/bin:/usr/bin
XDG_RUNTIME_DIR=/run/droiddeck
XDG_DATA_HOME=/root/.local/share
BL_WIDTH=1280
BL_HEIGHT=800
BL_REFRESH=60
BL_GAMESCOPE_ARGS=--backend headless
BL_MANGOAPP=0
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json
GLIBC_TUNABLES=glibc.pthread.rseq=0
BL_LAUNCH_DIR=/run/launch
BL_DEBUG_DIR=/run/debug
BL_STEAM_EXIT_FILE=/run/steam-exit
BL_LOG=/root/session.log
BL_ADDED_GAMES=
BL_ANDROID_CLIPBOARD=
BL_CDP_PORT=
BL_CLIENT_CPUS=
BL_GAME_CPUS=
BL_RAM_CAP_MB=
BL_SHADER_PRECACHE=
BL_STEAM_LANGUAGE=
BL_STEAM_UI=
BL_VK_DRIVER=
ENV
docker rm -f droiddeck-googlebook-session >/dev/null 2>&1 || true
printf '127.0.0.1 localhost DroidDeck\n::1 localhost DroidDeck\n127.0.0.1 crash.steampowered.com\n' > "$WORK/hosts"
# As on the device: the guest hostname (DroidDeck) maps to loopback, and /dev/shm is a full-size directory, not
# Docker's 64 MB (Chromium's GPU ring buffers live there). Crash reports stay local while testing.
docker run -d --name droiddeck-googlebook-session --hostname DroidDeck --shm-size=2g -u 1000:1000 --device "$NODE" \
  --tmpfs /tmp:mode=1777 --tmpfs /run:mode=1777 -v "$WORK/hosts":/etc/hosts:ro -v "$WORK/home":/root --env-file "$WORK/session.env" \
  droiddeck-googlebook-session:test bash -c 'mkdir -p /run/droiddeck /run/launch /run/debug && exec droiddeck-session steam'
echo "session log: $WORK/home/session.log; Steam logs: $WORK/home/.local/share/Steam/logs"
