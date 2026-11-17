#!/bin/bash
# Zips the BeamNG mod into dist/gyro_steer.zip, ready to drop into BeamNG's mods folder.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/version.sh >/dev/null
mkdir -p dist
rm -f dist/gyro_steer.zip
(cd mod/gyro_steer && zip -q -r -X ../../dist/gyro_steer.zip lua scripts -x '*.DS_Store')
echo "dist/gyro_steer.zip"
