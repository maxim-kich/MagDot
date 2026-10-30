#!/bin/bash
# Sign nested code inside-out. Never use --deep to sign a release.
set -euo pipefail
APP="$1"
IDENTITY="$2"
MODE="$3"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
OPTIONS=(--force --sign "$IDENTITY")
if [ "$MODE" = release ]; then OPTIONS+=(--options runtime --timestamp); fi
for component in \
  "Versions/B/XPCServices/Downloader.xpc" \
  "Versions/B/XPCServices/Installer.xpc" \
  "Versions/B/Autoupdate" \
  "Versions/B/Updater.app"; do
  codesign "${OPTIONS[@]}" "$FRAMEWORK/$component"
done
codesign "${OPTIONS[@]}" "$FRAMEWORK"
