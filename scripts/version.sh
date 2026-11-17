#!/bin/bash
# Prints the version from Cargo.toml, after checking the mod says the same.
set -euo pipefail
cd "$(dirname "$0")/.."
app=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
mod=$(sed -n "s/^local VERSION = '\([^']*\)'.*/\1/p" mod/gyro_steer/lua/ge/extensions/gyroSteer.lua)
if [ "$app" != "$mod" ]; then
  echo "Version mismatch: Cargo.toml says $app, the mod's gyroSteer.lua says $mod" >&2
  exit 1
fi
echo "$app"
