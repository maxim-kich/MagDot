#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
make
./scripts/fetch-sparkle.sh
SPARKLE="$PWD/build/sparkle"
FRAMEWORKS="$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64"
APP="${MAGDOT_APP_PATH:-build/MagDot.app}"
VERSION=$(cat VERSION)
BUILD_NUMBER=$(cat BUILD_NUMBER)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp app/MagDot.swift build/main.swift
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O build/main.swift app/UpdateChecker.swift app/InAppUpdater.swift -F "$FRAMEWORKS" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -framework AppKit -framework ServiceManagement -lsqlite3 -o "$APP/Contents/MacOS/MagDot"
cp build/magdot "$APP/Contents/Resources/magdot"
./scripts/build-icon.sh "$APP"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MagDot</string>
<key>CFBundleIdentifier</key><string>com.maximkich.magdot</string>
<key>CFBundleIconFile</key><string>MagDot</string>
<key>CFBundleName</key><string>MagDot</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cat > "$APP/Contents/Library/LaunchDaemons/com.maximkich.magdot.helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.maximkich.magdot.helper</string>
<key>BundleProgram</key><string>Contents/Resources/magdot</string>
<key>ProgramArguments</key><array><string>magdot</string><string>daemon</string></array>
<key>ThrottleInterval</key><integer>1</integer>
<key>Sockets</key><dict><key>Listener</key><dict>
<key>SockPathName</key><string>/var/run/magdot.sock</string>
<key>SockPathMode</key><integer>438</integer>
<key>SockType</key><string>stream</string>
</dict></dict>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Legal"
ditto "$FRAMEWORKS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
  python3 scripts/thin-sparkle.py "$APP"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Legal/Sparkle-LICENSE.txt"
python3 scripts/configure-updater.py "$APP/Contents/Info.plist" config/sparkle-public-key.txt
MODE=development
if [ -n "${MAGDOT_TIMESTAMP_FLAG:-}" ]; then MODE=release; fi
scripts/sign-sparkle.sh "$APP" "${SIGN_IDENTITY:--}" "$MODE"
codesign --force --options runtime ${MAGDOT_TIMESTAMP_FLAG:-} --sign "${SIGN_IDENTITY:--}" "$APP/Contents/Resources/magdot"
APP_OPTIONS="--options runtime"
if [ "${SIGN_IDENTITY:--}" = "-" ]; then APP_OPTIONS=""; fi
codesign --force $APP_OPTIONS ${MAGDOT_TIMESTAMP_FLAG:-} --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/MagDot" --self-test
