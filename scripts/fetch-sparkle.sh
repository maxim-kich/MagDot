#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/sparkle
if [ ! -f build/sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Sparkle ]; then
  curl --fail --location --proto '=https' --tlsv1.2 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip' -o build/sparkle.zip
  echo '4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a  build/sparkle.zip' | shasum -a 256 -c -
  ditto -x -k build/sparkle.zip build/sparkle
fi
