#!/bin/sh
set -eu
APP="$1"
mkdir -p build/MagDot.iconset "$APP/Contents/Resources"
for size in 16 32 128 256 512; do
 sips -z "$size" "$size" assets/app-icon-transparent.png --out "build/MagDot.iconset/icon_${size}x${size}.png" >/dev/null
 double=$((size * 2))
 sips -z "$double" "$double" assets/app-icon-transparent.png --out "build/MagDot.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/MagDot.iconset -o "$APP/Contents/Resources/MagDot.icns"
# Use native macOS compression, retaining all icon resolutions.
python3 scripts/optimize-icon.py "$APP/Contents/Resources/MagDot.icns"
