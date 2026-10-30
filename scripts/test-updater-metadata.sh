#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/fetch-sparkle.sh
FRAMEWORKS="$PWD/build/sparkle/Sparkle.xcframework/macos-arm64_x86_64"
xcrun swiftc -swift-version 5 -F "$FRAMEWORKS" -framework Sparkle -Xlinker -rpath -Xlinker "$FRAMEWORKS" app/UpdateChecker.swift app/InAppUpdater.swift tests/updater-metadata/main.swift -o build/test-updater-metadata
build/test-updater-metadata
