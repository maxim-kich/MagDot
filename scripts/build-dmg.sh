#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export MAGDOT_DMG_APP="$1"
output="$2"
test ! -e "$output"
staging=$(mktemp -d "${TMPDIR:-/tmp}/magdot-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
swift scripts/render-dmg-background.swift "$staging/installer.tiff"
export MAGDOT_DMG_BACKGROUND="$staging/installer.tiff"
uvx --from dmgbuild==1.6.7 dmgbuild -s scripts/dmg-settings.py MagDot "$output"
hdiutil verify "$output"
