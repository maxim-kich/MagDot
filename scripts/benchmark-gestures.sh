#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/gesture-benchmark
xcrun clang -target arm64-apple-macos14.0 -O2 -Wno-unused-parameter -c app/Gestures/GestureSensor.c -o build/gesture-benchmark/Sensor.o
xcrun swiftc -O -target arm64-apple-macos14.0 tools/gesture-benchmark/main.swift app/Gestures/{LocationSensitivity,CalibrationPace,TapSignal,PreparedContextBank,PersonalCalibration,GestureRecording,GestureTrace,TapRepresentation,DiscriminativeTapModel}.swift build/gesture-benchmark/Sensor.o -import-objc-header app/Gestures/GestureSensor.h -framework IOKit -o build/gesture-benchmark/check
build/gesture-benchmark/check "$@"
