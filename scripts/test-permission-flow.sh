#!/bin/sh
# Isolated AppKit and injected ServiceManagement fixtures; never registers a helper.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/permission-flow
python3 - <<'PY'
from pathlib import Path
source=Path('app/MagDot.swift').read_text().split('if CommandLine.arguments.contains("--self-test") {')[0]
Path('build/permission-flow/main.swift').write_text(source+Path('tests/permission-flow/checks.swift').read_text())
PY
FRAMEWORKS="$PWD/build/sparkle/Sparkle.xcframework/macos-arm64_x86_64"
xcrun swiftc -D TESTING -swift-version 5 -O build/permission-flow/main.swift app/UpdateChecker.swift app/InAppUpdater.swift -F "$FRAMEWORKS" -framework Sparkle -Xlinker -rpath -Xlinker "$FRAMEWORKS" -framework AppKit -framework ServiceManagement -lsqlite3 -o build/permission-flow/checks
build/permission-flow/checks
build/permission-flow/checks --settings
