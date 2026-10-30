#!/bin/bash
# Generate one signed feed for one ordinary GitHub release. No network writes.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
ARCHIVE="$1"
OUTPUT="$2"
ACCOUNT="${MAGDOT_SPARKLE_ACCOUNT:-com.maximkich.magdot.updates}"
SPARKLE_ROOT="${MAGDOT_SCRATCH_PATH:-$PWD/build}/sparkle"
EXPECTED="MagDot-v${VERSION}-macOS-arm64.zip"
[[ "$(basename "$ARCHIVE")" = "$EXPECTED" ]] || { echo 'Unexpected release archive name' >&2; exit 1; }
PUBLIC_KEY_FILE="${MAGDOT_UPDATE_PUBLIC_KEY_FILE:-$PWD/config/sparkle-public-key.txt}"
test "$("$SPARKLE_ROOT/bin/generate_keys" --account "$ACCOUNT" -p)" = "$(cat "$PUBLIC_KEY_FILE")" || {
  echo 'Keychain signing key does not match the embedded public key.' >&2; exit 1;
}
test ! -e "$OUTPUT" || { echo 'Refusing to overwrite an existing feed.' >&2; exit 1; }
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/magdot-feed.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp "$ARCHIVE" "$STAGE/$EXPECTED"
"$SPARKLE_ROOT/bin/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 --maximum-versions 1 \
  --download-url-prefix "https://github.com/maxim-kich/MagDot/releases/download/v${VERSION}/" \
  -o "$STAGE/appcast.xml" "$STAGE"
"$SPARKLE_ROOT/bin/sign_update" --account "$ACCOUNT" --verify "$STAGE/appcast.xml"
cp "$STAGE/appcast.xml" "$OUTPUT"
printf 'Signed release feed: %s\n' "$OUTPUT"
