#!/usr/bin/env bash
# Re-signs a Googlebook build with the owner's key instead of the public AOSP testkey, which Play Protect rejects.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: GOOGLEBOOK_KEYSTORE=... GOOGLEBOOK_KEYSTORE_PASS_FILE=... $0 <in.apk> <out.apk>" >&2; exit 2; }
: "${GOOGLEBOOK_KEYSTORE:?}" "${GOOGLEBOOK_KEYSTORE_PASS_FILE:?}"
BUILD_TOOLS=${BUILD_TOOLS:-$(ls -d "${ANDROID_HOME:?}"/build-tools/* | sort -V | tail -1)}
ALIAS=${GOOGLEBOOK_KEY_ALIAS:-droiddeck-googlebook}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$BUILD_TOOLS/zipalign" -p -f 4 "$1" "$work/aligned.apk"
"$BUILD_TOOLS/apksigner" sign --ks "$GOOGLEBOOK_KEYSTORE" --ks-type PKCS12 --ks-key-alias "$ALIAS" \
  --ks-pass "file:$GOOGLEBOOK_KEYSTORE_PASS_FILE" \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true --out "$2" "$work/aligned.apk"
"$BUILD_TOOLS/apksigner" verify --print-certs "$2" | grep -E 'Signer #1 certificate (DN|SHA-256)'
