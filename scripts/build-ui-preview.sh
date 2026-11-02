#!/bin/sh
# Reuse installed signed helper/frameworks for UI-only iteration; no release feed or notarization.
set -eu
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Set Developer ID signing identity}"
APP="$PWD/build/MagDot-UI.app"
ditto /Applications/MagDot.app "$APP"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $(cat VERSION)" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $(cat BUILD_NUMBER)" "$APP/Contents/Info.plist"
mkdir -p build/gestures
xcrun clang -target arm64-apple-macos14.0 -O2 -Wall -Wextra -Wno-unused-parameter -c app/Gestures/GestureSensor.c -o build/gestures/Sensor.o
cp app/MagDot.swift build/main.swift
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O build/main.swift app/UpdateChecker.swift app/InAppUpdater.swift app/Gestures/*.swift build/gestures/Sensor.o -import-objc-header app/Gestures/GestureSensor.h -framework IOKit -F build/sparkle/Sparkle.xcframework/macos-arm64_x86_64 -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -framework AppKit -framework ServiceManagement -lsqlite3 -o "$APP/Contents/MacOS/MagDot"
cp app/Resources/MagSafeTapModels.json "$APP/Contents/Resources/MagSafeTapModels.json"
./scripts/build-icon.sh "$APP"
if [ "$(python3 scripts/thin-sparkle.py "$APP")" = changed ]; then
  scripts/sign-sparkle.sh "$APP" "$SIGN_IDENTITY" development
fi
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/MagDot" --self-test
