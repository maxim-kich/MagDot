#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun clang -c Sensor.c -o build/Sensor.o
xcrun swiftc -O -import-objc-header Sensor.h Detector.swift Profiles.swift Analysis.swift Microphone.swift Freeze.swift TypingTest.swift Gesture.swift GestureDataset.swift SingleTapDataset.swift SingleTapApp.swift ../../app/Gestures/PreparedContextBank.swift ../../app/Gestures/ConnectorModel.swift GestureApp.swift build/Sensor.o -framework AppKit -framework IOKit -framework AVFoundation -o build/TapLab
build/TapLab --self-test
APP="$PWD/build/Tap Lab.app"
mkdir -p "$APP/Contents/MacOS"
cp build/TapLab "$APP/Contents/MacOS/TapLab"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.magdot.taplab</string>
<key>CFBundleName</key><string>Tap Lab</string>
<key>CFBundleExecutable</key><string>TapLab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>Compare microphone tap features with accelerometer-only tap detection. Audio stays briefly in memory; only features are saved locally.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
