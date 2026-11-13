#!/bin/bash
# Builds the helper and copies the mod into BeamNG's mods folder inside the Wineskin wrapper.
# Set BEAMNG_MODS to use a different mods folder.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
MODS="${BEAMNG_MODS:-$HOME/Applications/beamng.app/Contents/SharedSupport/prefix/drive_c/users/Wineskin/AppData/Local/BeamNG/BeamNG.drive/current/mods}"
if [ ! -d "$MODS" ]; then
  echo "BeamNG's mods folder isn't at $MODS; set BEAMNG_MODS to the right folder." >&2
  exit 1
fi
mkdir -p "$MODS/unpacked"
rsync -a --delete mod/gyro_steer/ "$MODS/unpacked/gyro_steer/"
echo "Installed the mod in $MODS/unpacked/gyro_steer (restart BeamNG if it's running)"
