#!/bin/sh
# Compiles isolated fake-SMC binaries. Does not install a helper or write to SMC.
set -eu
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to a signing identity with a Team ID}"
mkdir -p build/test/MagDot.app/Contents/MacOS
clang -DMAGDOT_TEST -Wall -Wextra -Werror -O2 src/magdot.c -framework IOKit -framework CoreFoundation -framework Security -o build/test/helper
cp build/MagDot.app/Contents/Info.plist build/test/MagDot.app/Contents/Info.plist
cp app/MagDot.swift build/test/main.swift
xcrun swiftc -D TESTING -swift-version 5 -O build/test/main.swift app/UpdateChecker.swift app/InAppUpdater.swift -F build/sparkle/Sparkle.xcframework/macos-arm64_x86_64 -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -framework AppKit -framework ServiceManagement -lsqlite3 -o build/test/MagDot.app/Contents/MacOS/MagDot
mkdir -p build/test/MagDot.app/Contents/Frameworks
ditto build/sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework build/test/MagDot.app/Contents/Frameworks/Sparkle.framework
scripts/sign-sparkle.sh build/test/MagDot.app "$SIGN_IDENTITY" development
codesign --force --options runtime --sign "$SIGN_IDENTITY" build/test/helper
codesign --force --options runtime --sign "$SIGN_IDENTITY" build/test/MagDot.app
python3 tests/service.py

python3 tests/status-freshness.py
