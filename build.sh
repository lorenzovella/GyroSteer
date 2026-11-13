#!/bin/bash
# Builds GyroSteer.app (needs Xcode or the Command Line Tools: xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"
APP=GyroSteer.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/GyroSteer" helper/*.swift
cp helper/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
