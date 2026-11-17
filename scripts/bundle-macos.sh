#!/bin/bash
# Wraps a built gyrosteer binary into dist/GyroSteer.app and zips it as dist/GyroSteer-<version>-macOS.zip.
#   scripts/bundle-macos.sh [path/to/gyrosteer]     (default: target/release/gyrosteer)
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(./scripts/version.sh)
binary="${1:-target/release/gyrosteer}"
app=dist/GyroSteer.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/gyrosteer"
sed "s/@VERSION@/$version/g" packaging/macos/Info.plist > "$app/Contents/Info.plist"
cp assets/GyroSteer.icns "$app/Contents/Resources/GyroSteer.icns"
# Ad-hoc signature: enough for Apple Silicon to run it. Not notarized, so Gatekeeper asks once (see README).
codesign --force --deep --sign - "$app"
rm -f "dist/GyroSteer-$version-macOS.zip"
ditto -c -k --keepParent "$app" "dist/GyroSteer-$version-macOS.zip"
echo "$app"
echo "dist/GyroSteer-$version-macOS.zip"
