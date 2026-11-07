#!/bin/sh
# Isolated fixture database and Settings windows; never starts the LED helper.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/efficiency
python3 - <<'PY'
from pathlib import Path
source=Path('app/MagDot.swift').read_text().split('if CommandLine.arguments.contains("--self-test") {')[0]
Path('build/efficiency/main.swift').write_text(source+Path('tests/efficiency/checks.swift').read_text())
PY
FRAMEWORKS="$PWD/build/sparkle/Sparkle.xcframework/macos-arm64_x86_64"
xcrun swiftc -D TESTING -swift-version 5 -O build/efficiency/main.swift app/UpdateChecker.swift app/InAppUpdater.swift -F "$FRAMEWORKS" -framework Sparkle -Xlinker -rpath -Xlinker "$FRAMEWORKS" -framework AppKit -framework ServiceManagement -lsqlite3 -o build/efficiency/checks
build/efficiency/checks "$@"
